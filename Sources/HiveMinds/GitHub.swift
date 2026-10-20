import AppKit
import Observation

/// GitHub, through the GitHub CLI (gh), the same way Agent Office does it. gh keeps the sign-in in
/// the macOS Keychain; the app never sees or stores the token.
@MainActor @Observable
final class GitHubModel {
    enum Phase: Equatable {
        case checking
        case missing
        case signedOut
        case signingIn(code: String?)
        case connected(String)
    }

    struct Repo: Decodable, Identifiable, Hashable {
        let nameWithOwner: String
        let description: String?
        let isPrivate: Bool
        let pushedAt: Date?
        var id: String { nameWithOwner }
    }

    var phase: Phase = .checking
    var repos: [Repo] = []
    var loadingRepos = false
    var cloning: Set<String> = []
    /// Open issues per repository (owner/name), loaded when the Issues view asks.
    var issues: [String: [Issue]] = [:]
    var loadingIssues: Set<String> = []
    var issueErrors: [String: String] = [:]
    var error: String?
    var gh: String?
    private var loginProcess: Process?

    static let devicePage = URL(string: "https://github.com/login/device")!

    var login: String? {
        if case .connected(let l) = phase { return l }
        return nil
    }

    func refresh() async {
        guard let gh else { phase = .missing; return }
        let r = await Shell.run(gh, ["api", "user", "--jq", ".login"])
        let who = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.ok && !who.isEmpty {
            phase = .connected(who)
            if repos.isEmpty { await loadRepos() }
        } else if case .signingIn = phase {
            // Still waiting on the browser.
        } else {
            phase = .signedOut
        }
    }

    func loadRepos() async {
        guard let gh else { return }
        loadingRepos = true
        defer { loadingRepos = false }
        let r = await Shell.run(gh, ["repo", "list", "--limit", "400", "--json", "nameWithOwner,description,isPrivate,pushedAt"])
        guard r.ok else { error = "Couldn't list your repositories. \(r.message)"; return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let list = try? dec.decode([Repo].self, from: Data(r.out.utf8)) {
            repos = list.sorted { ($0.pushedAt ?? .distantPast) > ($1.pushedAt ?? .distantPast) }
        }
    }

    /// GitHub's device sign-in: gh asks GitHub for a one-time code, we show it, the person approves
    /// it in the browser, and gh saves the sign-in to the Keychain.
    func connect() {
        guard let gh, loginProcess == nil else { return }
        error = nil
        phase = .signingIn(code: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gh)
        p.arguments = ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web", "--skip-ssh-key"]
        var env = Shell.environment
        env["BROWSER"] = "true"   // We open the page ourselves, after showing the code.
        env["GH_BROWSER"] = "true"
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = output
        var text = ""
        output.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            guard !chunk.isEmpty else { return }
            Task { @MainActor in
                text += chunk
                if case .signingIn(nil) = self.phase,
                   let m = text.range(of: #"[A-Z0-9]{4}-[A-Z0-9]{4}"#, options: .regularExpression) {
                    self.phase = .signingIn(code: String(text[m]))
                    try? input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
                }
            }
        }
        p.terminationHandler = { proc in
            output.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                self.loginProcess = nil
                let status = proc.terminationStatus
                self.phase = .checking
                await self.refresh()
                if self.login == nil && status != 15 {
                    let last = text.split(separator: "\n").last.map(String.init) ?? ""
                    self.error = "GitHub sign-in didn't finish. \(last)"
                }
            }
        }
        do {
            try p.run()
            loginProcess = p
        } catch {
            phase = .signedOut
            self.error = "Couldn't start gh: \(error.localizedDescription)"
        }
    }

    func copyCodeAndOpen(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        NSWorkspace.shared.open(Self.devicePage)
    }

    func cancelSignIn() {
        loginProcess?.terminate()
        loginProcess = nil
        phase = .signedOut
    }

    func disconnect() async {
        guard let gh, let login else { return }
        let r = await Shell.run(gh, ["auth", "logout", "--hostname", "github.com", "--user", login])
        if !r.ok { error = "Couldn't sign out. \(r.message)" }
        repos = []
        phase = .checking
        await refresh()
    }
}
