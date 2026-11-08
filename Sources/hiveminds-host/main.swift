import Foundation
import HiveMindsCore
import HiveMindsProtocol
#if canImport(Glibc)
import Glibc
#endif

/// The host's own version, shown by `--version`. Releases set it (see the release protocol in CLAUDE.md).
let hostVersion = "0.5.0"

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
hiveminds-host \(hostVersion): runs HiveMinds projects and agents on this machine, for the HiveMinds app.

Usage:
  hiveminds-host serve [--name NAME] [--port 7420] [--listen ADDRESS]
                                          Run the host until Ctrl+C (agents stop with it)
  hiveminds-host projects add FOLDER [--name NAME]
  hiveminds-host projects list
  hiveminds-host projects remove FOLDER|NAME
  hiveminds-host pair                     Show a pairing code and allow devices (when serve has no terminal)
  hiveminds-host devices list
  hiveminds-host devices revoke NAME      Remove a paired device and disconnect it
  hiveminds-host status                   What a running host is doing
  hiveminds-host log [--follow]           Who connected, paired, started, typed into or deleted what
  hiveminds-host --version

It listens only on this machine's local-network addresses (port 7420), unless --listen says otherwise.
Settings: ~/.config/hiveminds-host/config.json · data: ~/.local/share/hiveminds-host/ · log: ~/.local/state/hiveminds-host/audit.log
Note: a paired device can run any command this user can, through its agents. The host isn't a sandbox.
"""

struct Arguments {
    var words: [String]
    var options: [String: String] = [:]
    var flags: Set<String> = []

    /// Splits `--name value`, `--name=value` and bare `--flag`s (those in `flagNames`) from the words.
    init(_ raw: [String], flagNames: Set<String>) throws {
        words = []
        var i = 0
        while i < raw.count {
            let a = raw[i]
            if a.hasPrefix("--") && a.count > 2 {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    options[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if flagNames.contains(body) {
                    flags.insert(body)
                } else {
                    guard i + 1 < raw.count else { throw HostError("--\(body) needs a value.") }
                    options[body] = raw[i + 1]
                    i += 1
                }
            } else {
                words.append(a)
            }
            i += 1
        }
    }

    func only(_ allowed: Set<String>) throws {
        if let unknown = Set(options.keys).union(flags).subtracting(allowed).sorted().first {
            throw HostError("Unknown option --\(unknown). See `hiveminds-host --help`.")
        }
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let paths = Paths.standard()

/// Asks a running host; nil when none is running.
func ask(_ request: [String: Any], keepReading: ([String: Any]) -> Bool = { _ in false }) -> [String: Any]? {
    do { return try ControlClient.request(paths.controlSocket.path, request, keepReading: keepReading) } catch { fail("\(error)") }
}

func requireHost(_ request: [String: Any]) -> [String: Any] {
    guard let reply = ask(request) else { fail("The host isn't running. Start it with `hiveminds-host serve`.") }
    if let error = reply["error"] as? String { fail(error) }
    return reply
}

func projectsCommand(_ args: Arguments) throws {
    try paths.prepare()
    var config = try HostConfig.load(paths)
    switch args.words.dropFirst(2).first {
    case "add":
        try args.only(["name"])
        guard let folder = args.words.dropFirst(3).first else { throw HostError("Say which folder: hiveminds-host projects add <folder>") }
        let path = HostConfig.standardize(folder)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { throw HostError("There's no folder at \(path).") }
        if let existing = config.projects.first(where: { $0.path == path }) {
            print("\(existing.name) is already a project: \(path)")
            return
        }
        let name = args.options["name"] ?? URL(fileURLWithPath: path).lastPathComponent
        guard !config.projects.contains(where: { $0.name == name }) else {
            throw HostError("There's already a project called \(name). Pick another name with --name.")
        }
        config.projects.append(Project(name: name, path: path))
        try config.save(paths)
        _ = ask(["command": "reload-config"])
        let git = FileManager.default.fileExists(atPath: path + "/.git") ? "" : " (not a git repository, so its agents can't have their own branches)"
        print("Added \(name): \(path)\(git)")
    case "list":
        try args.only([])
        if config.projects.isEmpty { print("No projects yet. Add one with: hiveminds-host projects add <folder>") }
        for p in config.projects { print("\(p.name)\t\(p.path)") }
    case "remove":
        try args.only([])
        guard let which = args.words.dropFirst(3).first, let p = config.project(matching: which) else {
            throw HostError("That isn't a project here. See `hiveminds-host projects list`.")
        }
        if let status = ask(["command": "status"]), let agents = status["agents"] as? [[String: Any]],
           agents.contains(where: { $0["project"] as? String == p.name && $0["running"] as? Bool == true }) {
            throw HostError("\(p.name) has agents running. Stop them first.")
        }
        config.projects.removeAll { $0.id == p.id }
        try config.save(paths)
        _ = ask(["command": "reload-config"])
        print("Removed \(p.name). Its folder and files are untouched.")
    default:
        throw HostError("Say add, list or remove. See `hiveminds-host --help`.")
    }
}

func statusCommand() throws {
    guard let s = ask(["command": "status"]) else {
        print("The host isn't running.")
        let config = try HostConfig.load(paths)
        print(config.projects.isEmpty ? "No projects yet." : "Projects: " + config.projects.map(\.name).joined(separator: ", "))
        return
    }
    let since = Date(timeIntervalSince1970: TimeInterval(s["since"] as? Int ?? 0))
    print("HiveMinds host \"\(s["name"] as? String ?? "")\" is running (process \(s["pid"] as? Int ?? 0), since \(DateFormatter.localizedString(from: since, dateStyle: .none, timeStyle: .short))).")
    let projects = s["projects"] as? [[String: Any]] ?? []
    print("Projects: " + (projects.isEmpty ? "none" : projects.compactMap { $0["name"] as? String }.joined(separator: ", ")))
    let agents = s["agents"] as? [[String: Any]] ?? []
    let running = agents.filter { $0["running"] as? Bool == true }
    print("Agents: \(running.count) running, \(agents.count) in all.")
    for a in agents {
        let status = AgentStatus(rawValue: a["status"] as? String ?? "")?.label ?? "?"
        let activity = a["activity"] as? String ?? ""
        print("  \((a["id"] as? String ?? "").prefix(8))  \(a["title"] as? String ?? "")  [\(a["project"] as? String ?? "")]  \(status)\(activity.isEmpty ? "" : " · \(activity)")")
    }
    let addresses = s["addresses"] as? [String] ?? []
    print("Listening on: " + (addresses.isEmpty ? "nothing yet" : addresses.joined(separator: ", ")) + ((s["announced"] as? Bool ?? false) ? " (announced on the network)" : " (not announced)"))
    print("Fingerprint: \(s["fingerprint"] as? String ?? "")")
    let devices = s["devices"] as? [String] ?? []
    print("Connected devices: " + (devices.isEmpty ? "none" : devices.joined(separator: ", ")))
}

/// Hidden, for testing: start and drive agents on a running host.
func debugCommand(_ args: Arguments) throws {
    let words = Array(args.words.dropFirst(2))
    func id() throws -> String {
        guard words.count > 1 else { throw HostError("Say which agent (its id, or the start of it).") }
        return words[1]
    }
    switch words.first {
    case "remote":
        try remoteCommand(args)
    case "pair-code":
        // For tests: a new pairing code, printed.
        print(requireHost(["command": "pair-new-code"])["code"] as? String ?? "")
    case "pair-allow", "pair-deny":
        _ = requireHost(["command": "pair-answer", "allowed": words.first == "pair-allow"])
        print(words.first == "pair-allow" ? "Allowed." : "Not allowed.")
    case "paths":
        print("config\t\(paths.configFile.path)\ndata\t\(paths.data.path)\nstate\t\(paths.state.path)\nsocket\t\(paths.controlSocket.path)")
    case "start":
        try args.only(["task", "model", "effort", "access", "provider", "plan", "own-branch", "trust", "follow", "timeout"])
        guard words.count > 1 else { throw HostError("Say which project.") }
        let reply = requireHost(["command": "start", "project": words[1], "task": args.options["task"] ?? "",
                                 "model": args.options["model"] ?? "default", "effort": args.options["effort"] ?? "medium",
                                 "access": args.options["access"] ?? "auto", "provider": args.options["provider"] ?? "claude",
                                 "plan": args.flags.contains("plan"), "ownBranch": args.flags.contains("own-branch"),
                                 "trust": args.flags.contains("trust")])
        let agentID = reply["id"] as? String ?? ""
        print("Started \(agentID) in \(reply["cwd"] as? String ?? "")\((reply["branch"] as? String).map { " on \($0)" } ?? "")")
        if args.flags.contains("follow") { follow(agentID, timeout: args.options["timeout"]) }
    case "follow":
        try args.only(["timeout"])
        follow(try id(), timeout: args.options["timeout"])
    case "stop": _ = requireHost(["command": "stop", "id": try id()]); print("Stopping.")
    case "restart":
        try args.only(["trust"])
        _ = requireHost(["command": "restart", "id": try id(), "trust": args.flags.contains("trust")]); print("Restarting.")
    case "delete":
        let r = requireHost(["command": "delete", "id": try id()])
        print(r["keptFolder"] as? Bool == true ? "Deleted. Its folder was kept because it has changes that aren't committed." : "Deleted.")
    case "screen":
        let r = requireHost(["command": "screen", "id": try id()])
        print(r["screen"] as? String ?? "")
        if let menu = r["menu"] as? [String], !menu.isEmpty { print("Menu: \(menu)") }
    case "type":
        guard words.count > 2 else { throw HostError("Say what to type.") }
        _ = requireHost(["command": "type", "id": words[1], "text": words[2...].joined(separator: " ")])
    case "keys":
        // Escapes: \e (Esc), \r (Return), \t (Tab).
        let keys = words.dropFirst(2).map { $0.replacingOccurrences(of: "\\e", with: "\u{1b}").replacingOccurrences(of: "\\r", with: "\r").replacingOccurrences(of: "\\t", with: "\t") }
        _ = requireHost(["command": "keys", "id": try id(), "keys": keys])
    case "respond":
        guard words.count > 2 else { throw HostError("Say allow, decline, approve or keep-planning.") }
        let r = requireHost(["command": "respond", "id": words[1], "action": words[2], "text": words.dropFirst(3).joined(separator: " ")])
        print(r["activity"] as? String ?? "")
    default:
        throw HostError("debug paths|start|follow|stop|restart|delete|screen|type|keys|respond|remote")
    }
}

/// Prints each status change until the agent is done, needs someone, or ends. Exit code 0 when done, 2 when it
/// needs someone or went to sleep, 3 when `timeout` seconds passed first.
func follow(_ id: String, timeout: String?) {
    if let t = timeout.flatMap(Double.init), t > 0 {
        DispatchQueue.global().asyncAfter(deadline: .now() + t) {
            print("TIMEOUT after \(Int(t)) s")
            exit(3)
        }
    }
    var result: Int32 = 1
    var lastLine = ""
    _ = ask(["command": "follow", "id": id]) { event in
        if let error = event["error"] as? String { print(error); return false }
        if event["event"] as? String == "exited" { print("EXITED"); return false }
        let status = event["status"] as? String ?? ""
        var line = "STATE \(status) · \(event["activity"] as? String ?? "")"
        if let ask = event["ask"] as? [String: Any] { line += " · ASK \(ask["kind"] as? String ?? "")" }
        if line != lastLine { print(line); lastLine = line }
        if status == "done" { result = 0; return false }
        if status == "needsYou" || status == "asleep" { result = 2; return false }
        return true
    }
    exit(result)
}

do {
    let raw = Array(CommandLine.arguments.dropFirst())
    let args = try Arguments(["hiveminds-host"] + raw, flagNames: ["version", "help", "plan", "own-branch", "trust", "follow", "fresh", "no-pin"])
    if args.flags.contains("version") || args.words.dropFirst().first == "version" {
        print("hiveminds-host \(hostVersion)")
        exit(0)
    }
    switch args.words.dropFirst().first {
    case "serve":
        try args.only(["name", "port", "listen"])
        var port = HostProtocol.defaultPort
        if let p = args.options["port"] {
            guard let n = Int(p), (1...65535).contains(n) else { throw HostError("--port needs a number from 1 to 65535.") }
            port = n
        }
        if let l = args.options["listen"], l.isEmpty { throw HostError("--listen needs an address.") }
        try Host(paths: paths, name: args.options["name"], port: port, listen: args.options["listen"]).run()
    case "devices": try devicesCommand(args)
    case "log": try logCommand(args)
    case "pair": try pairCommand(args)
    case "projects": try projectsCommand(args)
    case "status": try args.only([]); try statusCommand()
    case "debug": try debugCommand(args)
    case nil, "help": print(usage)
    default:
        if args.flags.contains("help") { print(usage) } else { fail("Unknown command \"\(args.words[1])\". See `hiveminds-host --help`.") }
    }
} catch {
    fail("\(error)")
}
