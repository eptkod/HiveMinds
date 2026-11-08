import Foundation
import HiveMindsCore
import HiveMindsProtocol
import HiveMindsNet
import SwiftTerm
#if canImport(Glibc)
import Glibc
#endif

// `devices`, `log`, `pair`, and the hidden `debug remote` test client.

func devicesCommand(_ args: Arguments) throws {
    try paths.prepare()
    switch args.words.dropFirst(2).first {
    case "list", nil:
        try args.only([])
        var devices: [[String: Any]]
        var connected = Set<String>()
        if let r = ask(["command": "devices"]) {
            devices = r["devices"] as? [[String: Any]] ?? []
            connected = Set(r["connected"] as? [String] ?? [])
        } else {
            devices = try DeviceRegistry(file: paths.devicesFile).devices.map(Host.describe(device:))
        }
        guard !devices.isEmpty else { return print("No devices are paired with this host yet. Pair one with the HiveMinds app.") }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        for d in devices {
            let last = Date(timeIntervalSince1970: TimeInterval(d["lastUsed"] as? Int ?? 0))
            let id = d["id"] as? String ?? ""
            print("\(d["name"] as? String ?? "")\t\(d["fingerprint"] as? String ?? "")\t\(connected.contains(id) ? "connected now" : "last used \(f.string(from: last))")")
        }
    case "revoke":
        try args.only([])
        guard let which = args.words.dropFirst(3).first else { throw HostError("Say which device: hiveminds-host devices revoke <name>") }
        if let r = ask(["command": "revoke", "device": which]) {
            if let e = r["error"] as? String { throw HostError(e) }
            print("Removed \((r["revoked"] as? [String] ?? []).joined(separator: ", ")). It's been disconnected and will need to pair again.")
        } else {
            let gone = try DeviceRegistry(file: paths.devicesFile).revoke(which)
            guard !gone.isEmpty else { throw HostError("No paired device is called that. See `hiveminds-host devices list`.") }
            AuditLog(paths.auditFile).write("revoked", device: gone[0].info, detail: "while the host was stopped")
            print("Removed \(gone.map(\.name).joined(separator: ", ")). It will need to pair again.")
        }
    default:
        throw HostError("Say list or revoke. See `hiveminds-host --help`.")
    }
}

func logCommand(_ args: Arguments) throws -> Never {
    try args.only(["follow"])
    let url = paths.auditFile
    if let text = try? String(contentsOf: url, encoding: .utf8) {
        for line in text.split(separator: "\n") {
            if let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { print(AuditLog.describe(e)) }
        }
    } else if !args.flags.contains("follow") {
        print("Nothing in the audit log yet.")
    }
    guard args.flags.contains("follow") else { exit(0) }
    if !FileManager.default.fileExists(atPath: url.path) {
        try paths.prepare()
        _ = AuditLog(url)
    }
    let tail = EventTail(url: url) { e in print(AuditLog.describe(e)) }
    withExtendedLifetime(tail) { dispatchMain() }
}

/// `hiveminds-host pair`: for a host without a terminal (started by systemd). Shows pairing codes and asks whether
/// to allow each device, here.
func pairCommand(_ args: Arguments) throws -> Never {
    try args.only([])
    let console = Console()
    guard console.isInteractive else { throw HostError("Run `hiveminds-host pair` in a terminal: it shows the code and asks you to allow each device.") }
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigint.setEventHandler { console.restore(); print(""); exit(0) }
    sigint.resume()
    console.onKey = { key in
        if key == "p" || key == "P" { _ = ask(["command": "pair-new-code"]) }
    }
    let socket = paths.controlSocket.path
    // Touched on the main queue only.
    let questions = QueueBox<[String: UUID]>([:])
    DispatchQueue.global().async {
        let reply = try? ControlClient.request(socket, ["command": "pair"]) { event in
            DispatchQueue.main.async {
                switch event["event"] as? String {
                case "hello":
                    print("Pairing with HiveMinds host \"\(event["name"] as? String ?? "")\". Press p for a new code, Ctrl+C to stop.")
                case "code":
                    print("Pairing code: \(event["code"] as? String ?? "") (valid \(event["seconds"] as? Int ?? 60) s). Open HiveMinds on the device and pick this host.")
                case "expired":
                    print("The pairing code expired. Press p for a new one.")
                case "question":
                    guard let id = event["id"] as? String else { return }
                    questions.value[id] = console.ask(event["prompt"] as? String ?? "Allow this device? [y/N]") { yes in
                        DispatchQueue.global().async { _ = try? ControlClient.request(socket, ["command": "pair-answer", "id": id, "allowed": yes]) }
                        print(yes ? "Allowed." : "Not allowed.")
                    }
                case "answered":
                    if let id = event["id"] as? String, let q = questions.value.removeValue(forKey: id) {
                        console.withdraw(q, note: (event["allowed"] as? Bool == true) ? "Allowed on the host." : "Not allowed.")
                    }
                default: break
                }
            }
            return true
        }
        DispatchQueue.main.async {
            console.restore()
            print(reply == nil ? "The host isn't running. Start it with `hiveminds-host serve`." : "The host stopped.")
            exit(reply == nil ? 1 : 0)
        }
    }
    dispatchMain()
}

// MARK: The hidden test client

/// `hiveminds-host debug remote ADDRESS[:PORT] ACTION …`: a minimal HiveMinds client for testing a host over the
/// network, as the app will talk to it. Keeps its own identity and tokens in the state folder (`test-client/`).
func remoteCommand(_ args: Arguments) throws -> Never {
    try args.only(["name", "origin", "host-header", "path", "fresh", "no-pin", "seconds", "task", "model", "own-branch",
                   "token", "cols", "rows", "protocol", "type"])
    let words = Array(args.words.dropFirst(3))
    guard let target = words.first, let action = words.dropFirst().first else {
        throw HostError("debug remote ADDRESS[:PORT] pair CODE|hello|projects|agents|create PROJECT|attach ID|type ID TEXT|answer ID ACTION|take ID|delete ID|changes ID|history|watch")
    }
    let rest = Array(words.dropFirst(2))
    var host = target, port = HostProtocol.defaultPort
    if let r = target.range(of: ":", options: .backwards), !target.hasSuffix("]"), target.filter({ $0 == ":" }).count == 1, let p = Int(target[r.upperBound...]) {
        host = String(target[..<r.lowerBound]); port = p
    } else if target.hasPrefix("["), let close = target.firstIndex(of: "]") {
        host = String(target[target.index(after: target.startIndex)..<close])
        if let p = Int(target[target.index(after: close)...].dropFirst()) { port = p }
    }
    let dir = paths.testClientDir
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    chmod(dir.path, 0o700)
    let identity = args.flags.contains("fresh") ? try Identity(commonName: "test-device") : try Identity.loadOrCreate(in: dir, commonName: "test-device")
    let storeFile = dir.appendingPathComponent("hosts.json")
    var store = (try? JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: storeFile))) ?? [:]
    let key = "\(host):\(port)"
    let deviceName = args.options["name"] ?? "Test client"

    let done = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0
    Task {
        let client = HostClient(identity: identity)
        do {
            let pinned = args.flags.contains("no-pin") || args.flags.contains("fresh") ? nil : store[key]?["fingerprint"]
            try await client.connect(host: host, port: port, pinned: pinned, origin: args.options["origin"],
                                     hostHeader: args.options["host-header"] ?? HostProtocol.hostHeader, path: args.options["path"] ?? HostProtocol.path)
            print("CONNECTED fingerprint \(Identity.display(client.hostFingerprint ?? ""))")
            let token = args.options["token"] ?? (args.flags.contains("fresh") ? nil : store[key]?["token"])
            let hello: HelloResult
            if let v = args.options["protocol"].flatMap(Int.init) {
                client.send(.hello(Hello(protocol: v, client: "hiveminds-host test client", deviceName: deviceName, token: token)))
                guard case .incompatible(let i) = try await client.next() else { throw ClientError.closed }
                hello = .incompatible(i)
            } else {
                hello = try await client.hello(client: "hiveminds-host test client \(hostVersion)", deviceName: deviceName, token: token)
            }
            switch hello {
            case .welcome(let w): print("WELCOME \(w.hostName) as \(w.device.name)")
            case .pairingRequired(let p): print("PAIRING-REQUIRED \(p.reason) host \(p.hostId)")
            case .incompatible(let i): print("INCOMPATIBLE update \(i.update): \(i.message)"); exitCode = 4; done.signal(); return
            }
            func needWelcome() throws {
                if case .welcome = hello { return }
                throw ClientError.pairingFailed("Not signed in (pair first).")
            }
            func printEvents(_ id: UUID) {
                client.onMessage = { m in
                    switch m {
                    case .event(.resized(_, let c, let rows)): print("RESIZED \(c)x\(rows)")
                    case .event(.controller(_, let c, let from)): print("CONTROLLER \(c?.name ?? "-")\(from.map { " (took over from \($0.name))" } ?? "")")
                    case .event(.viewers(_, let v)): print("VIEWERS \(v.map(\.name))")
                    case .event(.promptResolved(_, let by, let activity)): print("RESOLVED by \(by.name): \(activity)")
                    case .event(.inputRefused(_, let c)): print("REFUSED \(c.name) is typing")
                    case .event(.hostStopping(let reason, let message)): print("HOST-STOPPING \(reason): \(message)")
                    case .event(.agentUpdated(let a)) where a.id == id: print("UPDATED \(a.status) · \(a.activity)")
                    default: break
                    }
                }
                client.onClose = { print("CLOSED") }
            }
            func agentID(_ s: String) async throws -> UUID {
                if let u = UUID(uuidString: s) { return u }
                let all = try await client.request(.listAgents).agents ?? []
                guard let a = all.first(where: { $0.id.uuidString.lowercased().hasPrefix(s.lowercased()) }) else { throw ClientError.pairingFailed("No agent \(s).") }
                return a.id
            }
            switch action {
            case "hello":
                break
            case "pair":
                guard let code = rest.first?.replacingOccurrences(of: " ", with: "") else { throw HostError("pair needs the code") }
                let (tok, welcome) = try await client.pair(code: code, deviceName: deviceName)
                store[key] = ["token": tok, "fingerprint": client.hostFingerprint ?? ""]
                try JSONEncoder().encode(store).write(to: storeFile, options: .atomic)
                chmod(storeFile.path, 0o600)
                print("PAIRED with \(welcome.hostName) as \(welcome.device.name) (\(welcome.device.id))")
            case "projects":
                try needWelcome()
                for p in try await client.request(.listProjects).projects ?? [] { print("PROJECT \(p.id) \(p.name) git=\(p.isGitRepo)") }
            case "agents":
                try needWelcome()
                for a in try await client.request(.listAgents).agents ?? [] {
                    print("AGENT \(a.id.uuidString.prefix(8)) \(a.status) \(a.title) · \(a.activity) running=\(a.running) viewers=\(a.viewers.map(\.name)) controller=\(a.controller?.name ?? "-") startedBy=\(a.startedBy?.name ?? "-")")
                }
            case "history":
                try needWelcome()
                for a in try await client.request(.history).agents ?? [] { print("PAST \(a.id.uuidString.prefix(8)) \(a.title)") }
            case "create":
                try needWelcome()
                guard let project = rest.first else { throw HostError("create needs a project name or id") }
                let projects = try await client.request(.listProjects).projects ?? []
                guard let p = projects.first(where: { $0.name == project || $0.id.uuidString == project }) else { throw HostError("No project \(project) on the host.") }
                let r = try await client.request(.createAgent(CreateAgent(projectId: p.id, model: args.options["model"] ?? "default",
                                                                           task: args.options["task"] ?? "", ownBranch: args.flags.contains("own-branch"))))
                print("CREATED \(r.agent?.id.uuidString ?? "?") \(r.agent?.branch ?? "")")
            case "attach", "watch":
                try needWelcome()
                guard let s = rest.first else { throw HostError("attach needs an agent") }
                let id = try await agentID(s)
                let seconds = Double(args.options["seconds"] ?? "3") ?? 3
                let r = try await client.request(.attach(AgentRef(id)))
                let term = TerminalBox(cols: r.cols ?? 120, rows: r.rows ?? 40)
                client.onFrame = { f in
                    guard f.agentID == id else { return }
                    if f.kind == .snapshot { term.reset() }
                    term.feed(f.bytes)
                }
                printEvents(id)
                let showEvent = client.onMessage
                client.onMessage = { m in
                    if case .event(.resized(_, let c, let rows)) = m { term.resize(c, rows) }
                    showEvent(m)
                }
                try await Task.sleep(for: .seconds(seconds))
                print("SCREEN-BEGIN")
                print(term.text)
                print("SCREEN-END")
            case "type":
                try needWelcome()
                guard rest.count >= 2 else { throw HostError("type needs an agent and text") }
                let id = try await agentID(rest[0])
                _ = try await client.request(.typeText(TypeText(id, text: rest[1...].joined(separator: " "))))
                print("TYPED")
            case "keys":
                try needWelcome()
                guard rest.count >= 2 else { throw HostError("keys needs an agent and keys") }
                let id = try await agentID(rest[0])
                let keys = rest[1...].joined(separator: " ").replacingOccurrences(of: "\\e", with: "\u{1b}").replacingOccurrences(of: "\\r", with: "\r")
                client.send(frame: TerminalFrame(.input, id, Array(keys.utf8)))
                try await Task.sleep(for: .milliseconds(500))
                print("SENT")
            case "take":
                try needWelcome()
                guard let s = rest.first else { throw HostError("take needs an agent") }
                let id = try await agentID(s)
                printEvents(id)
                let r = try await client.request(.takeControl(SizedAgentRef(id, cols: Int(args.options["cols"] ?? "100") ?? 100,
                                                                            rows: Int(args.options["rows"] ?? "30") ?? 30)))
                print("CONTROLLING \(r.agent?.controller?.name ?? "?") \(r.agent?.cols ?? 0)x\(r.agent?.rows ?? 0)")
                // Typing and staying connected keep control (it's let go when a device disconnects).
                if let text = args.options["type"] {
                    _ = try await client.request(.typeText(TypeText(id, text: text)))
                    print("TYPED")
                }
                if let seconds = args.options["seconds"].flatMap(Double.init) { try await Task.sleep(for: .seconds(seconds)) }
            case "answer":
                try needWelcome()
                guard rest.count >= 2 else { throw HostError("answer needs an agent and allow|decline|approvePlan|keepPlanning") }
                let r = try await client.request(.answer(Answer(try await agentID(rest[0]), action: rest[1], feedback: rest.dropFirst(2).joined(separator: " "))))
                print("ANSWERED \(r.activity ?? "")")
            case "delete":
                try needWelcome()
                guard let s = rest.first else { throw HostError("delete needs an agent") }
                let r = try await client.request(.deleteAgent(AgentRef(try await agentID(s))))
                print("DELETED keptFolder=\(r.keptFolder ?? false)")
            case "changes":
                try needWelcome()
                guard let s = rest.first else { throw HostError("changes needs an agent") }
                let r = try await client.request(.changes(AgentRef(try await agentID(s))))
                print("CHANGES against \(r.base ?? "?"): \((r.files ?? []).map { "\($0.path) +\($0.added ?? 0) -\($0.removed ?? 0)" })")
            default:
                throw HostError("Unknown action \(action).")
            }
            client.close()
        } catch let e as ClientError {
            print("ERROR \(e.codeForScripts): \(e)")
            exitCode = 2
        } catch {
            print("ERROR other: \(error)")
            exitCode = 2
        }
        done.signal()
    }
    done.wait()
    exit(exitCode)
}

private extension ClientError {
    var codeForScripts: String {
        switch self {
        case .host(let e): e.code
        case .identityChanged: "identityChanged"
        case .refused(let s): "refused(\(s))"
        case .cantConnect: "cantConnect"
        case .closed: "closed"
        case .timedOut: "timedOut"
        case .pairingFailed: "pairingFailed"
        }
    }
}

/// A headless terminal for the test client, fed from snapshot and output frames.
final class TerminalBox: TerminalDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var terminal: Terminal!
    private var cols: Int, rows: Int

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 1000))
    }

    // A viewer's terminal never answers the program; only the host's does.
    func send(source: Terminal, data: ArraySlice<UInt8>) {}

    func reset() {
        lock.withLock { terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, scrollback: 1000)) }
    }

    func resize(_ c: Int, _ r: Int) {
        lock.withLock {
            cols = c
            rows = r
            terminal.resize(cols: c, rows: r)
        }
    }

    func feed(_ bytes: [UInt8]) { lock.withLock { terminal.feed(byteArray: bytes) } }
    var text: String { lock.withLock { TerminalSnapshot.screenText(terminal) } }
}
