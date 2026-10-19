import Foundation

/// Running command-line tools. A Mac app opened from Finder doesn't get the user's shell PATH,
/// so we ask the login shell for it once and use it for every tool we look for or start.
enum Shell {
    static let loginPath: String = resolveLoginPath()

    private static func resolveLoginPath() -> String {
        let home = NSHomeDirectory()
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local",
                        "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var found: [String] = []
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-i", "-c", "printf '__HM__%s__HM__' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: killer)
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            killer.cancel()
            if let r = text.range(of: "__HM__"), let e = text.range(of: "__HM__", range: r.upperBound..<text.endIndex) {
                found = text[r.upperBound..<e.lowerBound].split(separator: ":").map(String.init)
            }
        }
        var seen = Set<String>()
        return (found + fallback).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// The app's environment with the login PATH, minus variables that would confuse a child agent.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("AGENT_OFFICE_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    static func which(_ name: String) -> String? {
        for dir in loginPath.split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    struct Result {
        var status: Int32
        var out: String
        var err: String
        var ok: Bool { status == 0 }
        var message: String {
            let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return e.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : e
        }
    }

    static func run(_ exe: String, _ args: [String], cwd: String? = nil) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                p.environment = environment
                let o = Pipe(), e = Pipe()
                p.standardOutput = o
                p.standardError = e
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Result(status: -1, out: "", err: error.localizedDescription))
                    return
                }
                var od = Data(), ed = Data()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { od = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.enter(); DispatchQueue.global().async { ed = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                g.wait()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus,
                                              out: String(decoding: od, as: UTF8.self),
                                              err: String(decoding: ed, as: UTF8.self)))
            }
        }
    }
}

struct Tools {
    var claude: String?
    var codex: String?
    var gh: String?
    var git: String?

    static func detect() -> Tools {
        Tools(claude: Shell.which("claude"), codex: Shell.which("codex"), gh: Shell.which("gh"), git: Shell.which("git"))
    }

    func path(for provider: Provider) -> String? {
        switch provider {
        case .claude: claude
        case .codex: codex
        }
    }

    var providers: [Provider] { Provider.allCases.filter { path(for: $0) != nil } }
}
