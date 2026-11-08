import Foundation
import HiveMindsCore
#if canImport(Glibc)
import Glibc
#endif

/// Where the host keeps things, following the XDG base directories on Linux and macOS alike:
/// - config: `~/.config/hiveminds-host/config.json` (name and projects; safe to edit while it's stopped)
/// - data: `~/.local/share/hiveminds-host/` (agents, hook settings, event logs; later the key, certificate and token hashes)
/// - state: `~/.local/state/hiveminds-host/` (the lock, the control socket; later the audit log)
/// Every folder is 0700 and every file 0600: the host runs commands, so nobody else on the machine should touch them.
struct Paths {
    let config: URL
    let data: URL
    let state: URL

    static func standard(environment env: [String: String] = ProcessInfo.processInfo.environment) -> Paths {
        let home = URL(fileURLWithPath: env["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        func base(_ key: String, _ fallback: String) -> URL {
            if let v = env[key], v.hasPrefix("/") { return URL(fileURLWithPath: v, isDirectory: true) }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        return Paths(config: base("XDG_CONFIG_HOME", ".config").appendingPathComponent("hiveminds-host", isDirectory: true),
                     data: base("XDG_DATA_HOME", ".local/share").appendingPathComponent("hiveminds-host", isDirectory: true),
                     state: base("XDG_STATE_HOME", ".local/state").appendingPathComponent("hiveminds-host", isDirectory: true),
                     runtimeDir: env["XDG_RUNTIME_DIR"])
    }

    var configFile: URL { config.appendingPathComponent("config.json") }
    var agentsFile: URL { data.appendingPathComponent("agents.json") }
    var eventsDir: URL { data.appendingPathComponent("events", isDirectory: true) }
    var statusDir: URL { data.appendingPathComponent("status", isDirectory: true) }
    var lockFile: URL { state.appendingPathComponent("serve.lock") }
    var auditFile: URL { state.appendingPathComponent("audit.log") }
    var devicesFile: URL { data.appendingPathComponent("devices.json") }
    var identityDir: URL { data.appendingPathComponent("identity", isDirectory: true) }
    var hostIDFile: URL { data.appendingPathComponent("host-id") }
    /// The hidden test client's own identity and tokens (`debug remote`).
    var testClientDir: URL { state.appendingPathComponent("test-client", isDirectory: true) }
    /// Where `serve` listens for `status` and the debug commands. Unix socket paths are short (about 104 bytes),
    /// so: `$XDG_RUNTIME_DIR` when set (the usual place on Linux), else the state folder, else (a long home path)
    /// an owner-only folder in /tmp.
    var controlSocket: URL {
        let name = "hiveminds-host.sock"
        if let runtime = runtimeDir, runtime.hasPrefix("/") {
            let url = URL(fileURLWithPath: runtime, isDirectory: true).appendingPathComponent(name)
            if url.path.utf8.count < 100 { return url }
        }
        let inState = state.appendingPathComponent(name)
        if inState.path.utf8.count < 100 { return inState }
        // Named after the state folder, so two hosts with different settings never share a socket.
        return URL(fileURLWithPath: "/tmp/hiveminds-host-\(getuid())", isDirectory: true)
            .appendingPathComponent("\(Paths.shortHash(state.path)).sock")
    }
    var runtimeDir: String?

    /// A short, stable name for a path (FNV-1a), for the socket fallback.
    static func shortHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    var hookFiles: HookSettings.Files {
        HookSettings.Files(hooks: data.appendingPathComponent("claude-hooks.json"),
                           hooksWithKey: data.appendingPathComponent("claude-hooks-api-key.json"),
                           keyOnly: data.appendingPathComponent("claude-api-key.json"),
                           statusLineScript: data.appendingPathComponent("statusline.sh"),
                           usage: data.appendingPathComponent("usage.json"))
    }

    /// Makes the folders, owner-only.
    func prepare() throws {
        for dir in [config, data, state, eventsDir, statusDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            chmod(dir.path, 0o700)
        }
        let socketDir = controlSocket.deletingLastPathComponent().path
        if socketDir.hasPrefix("/tmp/") {
            // A shared folder: make ours, and refuse one someone else made or opened up.
            mkdir(socketDir, 0o700)
            var st = stat()
            guard lstat(socketDir, &st) == 0, st.st_uid == getuid(), (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o077 == 0 else {
                throw HostError("\(socketDir) isn't a private folder of yours, so the host won't use it. Remove it, or set XDG_RUNTIME_DIR.")
            }
        }
    }
}

/// Writes a file atomically, readable by its owner only.
func writePrivate(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    chmod(url.path, 0o600)
}
