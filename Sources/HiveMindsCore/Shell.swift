import Foundation
import CHiveMindsSystem
#if canImport(Glibc)
import Glibc
#endif

/// Running command-line tools. A Mac app opened from Finder doesn't get the user's shell PATH,
/// so we ask the login shell for it once and use it for every tool we look for or start.
package enum Shell {
    package static let loginPath: String = resolveLoginPath()

    private static func resolveLoginPath() -> String {
        let home = NSHomeDirectory()
        let fallback = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.claude/local",
                        "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var found: [String] = []
        #if os(macOS)
        let defaultShell = "/bin/zsh"
        #else
        let defaultShell = "/bin/sh"
        #endif
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? defaultShell
        let text = runDetached(shell, ["-l", "-i", "-c", "printf '__HM__%s__HM__' \"$PATH\""], timeout: 5)
        if let r = text.range(of: "__HM__"), let e = text.range(of: "__HM__", range: r.upperBound..<text.endIndex) {
            found = text[r.upperBound..<e.lowerBound].split(separator: ":").map(String.init)
        }
        var seen = Set<String>()
        return (found + fallback).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ":")
    }

    /// Runs a program in a session of its own with no terminal, and returns what it printed. An interactive shell
    /// started from a host running in a terminal would otherwise try to take that terminal over and be stopped,
    /// and a stopped process ignores everything but SIGKILL: so after `timeout` seconds it gets SIGKILL.
    static func runDetached(_ exe: String, _ args: [String], timeout: TimeInterval) -> String {
        var fd: Int32 = -1
        var pid: pid_t = 0
        let argv = ([exe] + args).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for p in argv { free(p) }
            for p in envp { free(p) }
        }
        let err = argv.withUnsafeBufferPointer { a in
            envp.withUnsafeBufferPointer { e in hiveminds_spawn_detached(exe, a.baseAddress, e.baseAddress, &fd, &pid) }
        }
        guard err == 0 else { return "" }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let killer = DispatchWorkItem { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = handle.readDataToEndOfFile()
        killer.cancel()
        // Whatever it started in its session goes too.
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return String(decoding: data, as: UTF8.self)
    }

    /// The app's environment with the login PATH, minus variables that would confuse a child agent.
    package static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        for key in env.keys where key == "CLAUDECODE" || key.hasPrefix("CLAUDE_CODE_") || key.hasPrefix("AGENT_OFFICE_") {
            env.removeValue(forKey: key)
        }
        return env
    }

    package static func which(_ name: String) -> String? {
        for dir in loginPath.split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    package struct Result: Sendable {
        package var status: Int32
        package var out: String
        package var err: String
        package init(status: Int32, out: String, err: String) {
            self.status = status
            self.out = out
            self.err = err
        }
        package var ok: Bool { status == 0 }
        package var message: String {
            let e = err.trimmingCharacters(in: .whitespacesAndNewlines)
            return e.isEmpty ? out.trimmingCharacters(in: .whitespacesAndNewlines) : e
        }
    }

    package static func run(_ exe: String, _ args: [String], cwd: String? = nil, env extra: [String: String] = [:]) async -> Result {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
                p.environment = environment.merging(extra) { $1 }
                let o = Pipe(), e = Pipe()
                p.standardOutput = o
                p.standardError = e
                p.standardInput = FileHandle.nullDevice
                do { try p.run() } catch {
                    cont.resume(returning: Result(status: -1, out: "", err: error.localizedDescription))
                    return
                }
                // Both pipes are drained at once, so a tool that fills one while we wait on the other can't stall.
                let errors = Collected()
                let g = DispatchGroup()
                g.enter(); DispatchQueue.global().async { errors.data = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
                let od = o.fileHandleForReading.readDataToEndOfFile()
                g.wait()
                p.waitUntilExit()
                cont.resume(returning: Result(status: p.terminationStatus,
                                              out: String(decoding: od, as: UTF8.self),
                                              err: String(decoding: errors.data, as: UTF8.self)))
            }
        }
    }
}

/// Output read on another thread; the DispatchGroup wait orders the write before the read.
private final class Collected: @unchecked Sendable {
    var data = Data()
}

package struct Tools: Sendable {
    package var claude: String?
    package var codex: String?
    package var gh: String?
    package var git: String?

    package init(claude: String? = nil, codex: String? = nil, gh: String? = nil, git: String? = nil) {
        self.claude = claude
        self.codex = codex
        self.gh = gh
        self.git = git
    }

    package static func detect() -> Tools {
        Tools(claude: Shell.which("claude"), codex: Shell.which("codex"), gh: Shell.which("gh"), git: Shell.which("git"))
    }

    package func path(for provider: Provider) -> String? {
        switch provider {
        case .claude: claude
        case .codex: codex
        }
    }

    package var providers: [Provider] { Provider.allCases.filter { path(for: $0) != nil } }
}
