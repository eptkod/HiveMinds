import Foundation
import NIOCore
import NIOPosix
import Crypto
import SwiftTerm

setvbuf(stdout, nil, _IOLBF, 0)

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "  PASS  \(what)" : "  FAIL  \(what)")
    if !ok { failures += 1 }
}

func digest(_ b: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: b)) }

// MARK: - Host side

final class HostApp {
    let server: SpikeServer
    let agent: PtyAgent
    let identity: Identity
    var code: String
    private var tries = 0
    private var codeValid = true
    private var pairing: [ObjectIdentifier: (spake: Spake, key: SymmetricKey?)] = [:]
    private var viewers: [ObjectIdentifier: Channel] = [:]
    var paired: [String] = []

    init(identity: Identity, group: MultiThreadedEventLoopGroup, cols: Int, rows: Int, code: String) {
        self.identity = identity
        self.code = code
        server = SpikeServer(identity: identity, group: group)
        agent = PtyAgent(cols: cols, rows: rows)
        server.onMessage = { [unowned self] ch, fp, type, payload in agent.queue.async { self.handle(ch, fp, type, payload) } }
        server.onClose = { [unowned self] ch in agent.queue.async { self.viewers[ObjectIdentifier(ch)] = nil } }
        agent.onOutput = { [unowned self] bytes in for ch in viewers.values { server.send(ch, .output, bytes) } }
    }

    func newCode(_ c: String) { agent.queue.sync { code = c; tries = 0; codeValid = true } }

    /// Runs on agent.queue.
    private func handle(_ ch: Channel, _ clientFP: String, _ type: Frame, _ payload: [UInt8]) {
        let id = ObjectIdentifier(ch)
        switch type {
        case .pairStart:
            guard codeValid else { return server.send(ch, .pairResult, [2]) }
            let s = Spake(isClient: false, clientFP: clientFP, hostFP: identity.fingerprint, code: code)
            pairing[id] = (s, s.finish(payload))
            server.send(ch, .pairHost, s.message)
        case .pairConfirm:
            guard codeValid, let state = pairing.removeValue(forKey: id), let key = state.key else { return server.send(ch, .pairResult, [2]) }
            let expected = Spake.confirmation(key, role: "client", clientFP: clientFP, hostFP: identity.fingerprint)
            if constantTimeEqual(expected, payload) {
                codeValid = false  // single use
                paired.append(clientFP)
                let token = (0..<32).map { _ in UInt8.random(in: 0...255) }
                server.send(ch, .pairResult, [1] + Spake.confirmation(key, role: "host", clientFP: clientFP, hostFP: identity.fingerprint) + token)
            } else {
                tries += 1
                if tries >= 3 { codeValid = false }
                server.send(ch, .pairResult, [0])
            }
        case .attach:
            viewers[id] = ch
            server.send(ch, .snapshot, Snapshot.make(agent.terminal))
        case .detach:
            viewers[id] = nil
        case .input:
            agent.process.send(data: payload[...])
        case .sync:
            server.send(ch, .syncAck, payload + Snapshot.make(agent.terminal))
        default: break
        }
    }
}

func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}

// MARK: - Client side

final class Viewer {
    let client: SpikeClient
    let queue = DispatchQueue(label: "viewer")
    private(set) var terminal: Terminal
    private let delegate = SilentDelegate()
    private var pairState: (spake: Spake, key: SymmetricKey?)?
    private var pairDone: ((Bool) -> Void)?
    private var syncs: [UInt32: ([UInt8]) -> Void] = [:]
    private var snapshots = 0
    let cols: Int, rows: Int

    init(identity: Identity, group: MultiThreadedEventLoopGroup, cols: Int, rows: Int) {
        client = SpikeClient(identity: identity, group: group)
        self.cols = cols
        self.rows = rows
        terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 5000))
    }

    func connect(_ host: String, _ port: Int, pinned: String? = nil) throws {
        try client.connect(host: host, port: port, pinned: pinned, onMessage: { [unowned self] t, p in queue.async { self.handle(t, p) } })
    }

    private func handle(_ type: Frame, _ payload: [UInt8]) {
        switch type {
        case .pairHost:
            guard let state = pairState, let key = state.spake.finish(payload), let hostFP = client.hostFP else { pairDone?(false); return }
            pairState = (state.spake, key)
            client.send(.pairConfirm, Spake.confirmation(key, role: "client", clientFP: client.identity.fingerprint, hostFP: hostFP))
        case .pairResult:
            var ok = payload.first == 1
            if ok, let key = pairState?.key, let hostFP = client.hostFP {
                let expected = Spake.confirmation(key, role: "host", clientFP: client.identity.fingerprint, hostFP: hostFP)
                ok = constantTimeEqual(Array(payload[1..<33]), expected)  // the host proves it knew the code too
            }
            pairState = nil
            pairDone?(ok)
        case .snapshot:
            snapshots += 1
            terminal.feed(byteArray: payload)
        case .output:
            terminal.feed(byteArray: payload)
        case .syncAck:
            let id = payload[0..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            syncs.removeValue(forKey: id)?(Array(payload[4...]))
        default: break
        }
    }

    /// Runs the pairing exchange with a code; true when both sides proved they had the same code over this TLS channel.
    func pair(code: String) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var result = false
        queue.sync {
            let s = Spake(isClient: true, clientFP: client.identity.fingerprint, hostFP: client.hostFP ?? "", code: code)
            pairState = (s, nil)
            pairDone = { result = $0; sem.signal() }
            client.send(.pairStart, s.message)
        }
        return sem.wait(timeout: .now() + 5) == .success && result
    }

    func attach(fresh: Bool) {
        queue.sync {
            if fresh { terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 5000)) }
        }
        client.send(.attach, [])
    }
    func detach() { client.send(.detach, []) }
    func type(_ s: String) { client.send(.input, Array(s.utf8)) }

    /// Waits until everything the host sent before now has been fed in, and returns whether this terminal's
    /// snapshot matches the host's snapshot at that moment.
    func sync() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var same = false
        let id = UInt32.random(in: 0...UInt32.max)
        queue.sync {
            syncs[id] = { [unowned self] hostSnap in
                let mine = Snapshot.make(terminal)
                same = hostSnap == mine
                if !same {
                    let i = (0..<min(hostSnap.count, mine.count)).first { hostSnap[$0] != mine[$0] } ?? min(hostSnap.count, mine.count)
                    func show(_ b: [UInt8]) -> String { String(decoding: b[max(0, i - 60)..<min(b.count, i + 60)], as: UTF8.self).debugDescription }
                    print("        snapshot differs at byte \(i) of \(hostSnap.count)/\(mine.count)\n          host: \(show(hostSnap))\n          mine: \(show(mine))")
                    let rebuilt = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: 5000))
                    rebuilt.feed(byteArray: hostSnap)
                    for p in Snapshot.diff(rebuilt, terminal).prefix(6) { print("          " + p) }
                }
                sem.signal()
            }
        }
        client.send(.sync, withUnsafeBytes(of: id) { Array($0) })
        return sem.wait(timeout: .now() + 10) == .success && same
    }
}

// MARK: - Tests

func cryptoTests() throws {
    print("SPAKE2 and certificates")
    let host = try Identity(commonName: "hiveminds-host"), client = try Identity(commonName: "hiveminds-client")
    check(host.der.count > 100 && host.fingerprint.count == 64, "self-signed P-256 certificate (\(host.der.count) bytes, fingerprint \(host.fingerprint.prefix(16))…)")
    func run(_ c1: String, _ c2: String, clientSees: String, hostSees: String) -> Bool {
        let a = Spake(isClient: true, clientFP: client.fingerprint, hostFP: clientSees, code: c1)
        let b = Spake(isClient: false, clientFP: hostSees, hostFP: host.fingerprint, code: c2)
        guard let ka = a.finish(b.message), let kb = b.finish(a.message) else { return false }
        return ka.withUnsafeBytes { Array($0) } == kb.withUnsafeBytes { Array($0) }
    }
    check(run("482913", "482913", clientSees: host.fingerprint, hostSees: client.fingerprint), "same code, same channel: same key")
    check(!run("482913", "482914", clientSees: host.fingerprint, hostSees: client.fingerprint), "wrong code: different key")
    let mitm = try Identity(commonName: "evil")
    check(!run("482913", "482913", clientSees: mitm.fingerprint, hostSees: mitm.fingerprint), "relay with its own certificate, even knowing the code: different key")
}

func networkTests(group: MultiThreadedEventLoopGroup) throws {
    print("TLS, WebSocket, browser defences, pairing")
    let hostID = try Identity(commonName: "hiveminds-host")
    let app = HostApp(identity: hostID, group: group, cols: 80, rows: 24, code: "482913")
    app.server.log = { print("        host log: \($0)") }
    try app.server.start(host: "127.0.0.1", port: 0)
    let port = app.server.channel!.localAddress!.port!
    let devID = try Identity(commonName: "hiveminds-client")

    let browser = SpikeClient(identity: devID, group: group)
    check((try? browser.connect(host: "127.0.0.1", port: port, pinned: nil, origin: "http://evil.example", onMessage: { _, _ in })) == nil, "request with an Origin header is refused (HTTP 403)")
    let rebinding = SpikeClient(identity: devID, group: group)
    check((try? rebinding.connect(host: "127.0.0.1", port: port, pinned: nil, hostHeader: "evil.example", onMessage: { _, _ in })) == nil, "request with a foreign Host header is refused")

    let v = Viewer(identity: devID, group: group, cols: 80, rows: 24)
    try v.connect("127.0.0.1", port)
    check(v.client.hostFP == hostID.fingerprint, "client saw the host's certificate fingerprint in TLS")
    check(!v.pair(code: "111111"), "wrong code 1 refused")
    check(!v.pair(code: "222222"), "wrong code 2 refused")
    check(!v.pair(code: "333333"), "wrong code 3 refused")
    check(!v.pair(code: "482913"), "after 3 wrong tries even the right code is refused (needs a new code)")
    app.newCode("551204")
    check(v.pair(code: "551204"), "new code pairs, and the host proved it knew the code")
    check(!v.pair(code: "551204"), "code is single-use")
    check(app.paired == [devID.fingerprint], "host recorded the device by its certificate fingerprint")
    v.client.close()

    let again = Viewer(identity: devID, group: group, cols: 80, rows: 24)
    check((try? again.connect("127.0.0.1", port, pinned: hostID.fingerprint)) != nil, "reconnect with the pinned fingerprint works")
    again.client.close()
    let impostor = Viewer(identity: devID, group: group, cols: 80, rows: 24)
    check((try? impostor.connect("127.0.0.1", port, pinned: String(repeating: "0", count: 64))) == nil, "a host with a different certificate is refused")
    try app.server.channel?.close().wait()
}

/// A continuously attached viewer (ground truth: it saw every byte) and one that attaches late, detaches,
/// misses output, and reattaches into a fresh terminal. Both must end up identical to each other and the host.
func terminalScenario(_ name: String, group: MultiThreadedEventLoopGroup, exe: String, args: [String], cwd: String,
                      warmup: Double, input: String, settle: Double) throws {
    print("Terminal: \(name)")
    let cols = 100, rows = 30
    let app = HostApp(identity: try Identity(commonName: "hiveminds-host"), group: group, cols: cols, rows: rows, code: "000000")
    try app.server.start(host: "127.0.0.1", port: 0)
    let port = app.server.channel!.localAddress!.port!
    let a = Viewer(identity: try Identity(commonName: "a"), group: group, cols: cols, rows: rows)
    let b = Viewer(identity: try Identity(commonName: "b"), group: group, cols: cols, rows: rows)
    try a.connect("127.0.0.1", port)
    try b.connect("127.0.0.1", port)
    a.attach(fresh: true)
    check(a.sync(), "viewer A attached before start")
    app.agent.start(exe, args, cwd: cwd)
    Thread.sleep(forTimeInterval: warmup)
    b.attach(fresh: true)
    check(b.sync(), "viewer B joined late and matches the host")
    b.detach()
    a.type(input)
    Thread.sleep(forTimeInterval: settle)
    check(a.sync(), "viewer A followed typed input live")
    b.attach(fresh: true)
    let same = b.sync()
    check(same, "viewer B reattached into a fresh terminal and matches the host")
    _ = a.sync()
    let problems = a.queue.sync { b.queue.sync { Snapshot.diff(a.terminal, b.terminal) } }
    check(problems.isEmpty, "cell-by-cell: B (snapshot + stream) equals A (every byte live)" + (problems.isEmpty ? "" : ":\n          " + problems.joined(separator: "\n          ")))
    let bytes = app.agent.queue.sync { app.agent.bytesSeen }
    let snap = app.agent.queue.sync { Snapshot.make(app.agent.terminal).count }
    print("        program wrote \(bytes) bytes; snapshot is \(snap) bytes; alt screen: \(app.agent.queue.sync { app.agent.terminal.isCurrentBufferAlternate })")
    print("        --- screen as B sees it ---")
    let text = b.queue.sync { Snapshot.screenText(b.terminal) }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty { print("        | " + line) }
    app.agent.stop()
    a.client.close(); b.client.close()
    try app.server.channel?.close().wait()
}

let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hiveminds-spike-\(getpid())")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

let script = #"""
printf '\033[1;31mbold red\033[0m \033[38;5;208morange-256\033[0m \033[38;2;10;200;120mtruecolor\033[0m \033[4;3munderline italic\033[0m \033[7minverse\033[0m \033[2mdim\033[0m \033[9mstrike\033[0m\n'
printf 'wide: 你好世界 🙂👍 combining: e\314\201 done\n'
i=1; while [ $i -le 300 ]; do printf "line %03d \033[3%dmcolour\033[0m %s\n" $i $((i%8)) "$(printf '%*s' $((i%150)) '' | tr ' ' '=')"; i=$((i+1)); done
printf 'a link: \033]8;;https://example.com/docs\033\\example docs\033]8;;\033\\ after the link\n'
printf '\033[44m blue background to end of line \033[K\033[0m\n'
printf 'gap:\033[20Cafter a 20-cell gap\n'
printf '\033[41mred bg\033[5Xerased five\033[0m\n'
printf '\033[42m\033[Kgreen erase to end\033[0m\n'
printf 'cat is listening: '
exec cat
"""#
let alt = #"""
printf 'normal screen text before the full-screen program\n'
i=1; while [ $i -le 60 ]; do echo "scrollback $i"; i=$((i+1)); done
printf '\033[?1049h\033[2J\033[H\033[?1000h\033[?1006h\033[?2004h\033[?1h\033=\033[?25l\033[3;20r'
printf '\033[1;1H\033[1mTop line on the alternate screen\033[0m\033[10;5H\033[32mgreen at 10,5\033[0m\033[48;2;40;40;90m\033[12;1H\033[2K truecolor bar \033[0m\033[5;1H'
exec cat
"""#

let args = CommandLine.arguments
let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
switch args.dropFirst().first ?? "selftest" {
case "selftest":
    try cryptoTests()
    try networkTests(group: group)
    try terminalScenario("colours, wide characters, wrapped lines, 300 lines of scrollback", group: group, exe: "/bin/sh", args: ["-c", script], cwd: scratch.path, warmup: 1.0, input: "typed while B was away\r", settle: 0.5)
    try terminalScenario("alternate screen with mouse, paste and cursor modes, scroll region", group: group, exe: "/bin/sh", args: ["-c", alt], cwd: scratch.path, warmup: 1.0, input: "typed on the alt screen\r", settle: 0.5)
    if let claude = args.dropFirst(2).first {
        try terminalScenario("Claude Code (\(claude))", group: group, exe: claude, args: [], cwd: scratch.path, warmup: 8, input: "\u{1b}[B", settle: 1.5)
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
case "replay":
    // replay FILE COLS ROWS [LIMIT]: feeds a recorded byte stream into a headless terminal and prints the screen.
    var data = Array(try Data(contentsOf: URL(fileURLWithPath: args[2])))
    if args.count > 5, let n = Int(args[5]) { data = Array(data.prefix(n)) }
    let t = Terminal(delegate: SilentDelegate(), options: TerminalOptions(cols: Int(args[3])!, rows: Int(args[4])!, scrollback: 5000))
    t.feed(byteArray: data)
    print(Snapshot.screenText(t))
    exit(0)
case "trace":
    // trace FILE COLS ROWS: prints the cursor after every chunk (split before each ESC and after each LF).
    let data = Array(try Data(contentsOf: URL(fileURLWithPath: args[2])))
    let t = Terminal(delegate: SilentDelegate(), options: TerminalOptions(cols: Int(args[3])!, rows: Int(args[4])!, scrollback: 5000))
    var start = 0
    var out = ""
    for i in 0...data.count {
        let boundary = i == data.count || data[i] == 0x1b || (i > 0 && data[i - 1] == 0x0a)
        if boundary && i > start {
            t.feed(byteArray: Array(data[start..<i]))
            let c = t.getCursorLocation()
            out += "\(i) \(c.x) \(c.y)\n"
            start = i
        }
    }
    print(out, terminator: "")
    exit(0)
case "serve":
    // serve PORT CODE EXE [ARGS...]: a host on this machine, listening on every interface (spike only).
    let port = Int(args[2])!, code = args[3]
    let app = HostApp(identity: try Identity(commonName: "hiveminds-host"), group: group, cols: 100, rows: 30, code: code)
    try app.server.start(host: "0.0.0.0", port: port)
    let cwd = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("spike-projects/run-\(getpid())").path
    try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
    app.agent.onExit = { code in print("agent exited with \(code ?? -1)"); exit(0) }
    app.agent.start(args[4], Array(args.dropFirst(5)), cwd: cwd)
    print("host listening on port \(port), fingerprint \(app.identity.fingerprint.prefix(16))…, pairing code \(code), running \(args[4]) in \(cwd)")
    dispatchMain()
case "watch":
    // watch HOST PORT CODE INPUT-ESCAPED: pairs, then runs the A/B detach-reattach check against a remote host.
    let host = args[2], port = Int(args[3])!, code = args[4]
    let input = args[5].replacingOccurrences(of: "\\e", with: "\u{1b}").replacingOccurrences(of: "\\r", with: "\r")
    let cols = 100, rows = 30
    let devID = try Identity(commonName: "watcher")
    let pairer = Viewer(identity: devID, group: group, cols: cols, rows: rows)
    try pairer.connect(host, port)
    let hostFP = pairer.client.hostFP!
    check(pairer.pair(code: code), "paired over the network with code \(code) (host \(hostFP.prefix(16))…)")
    pairer.client.close()
    let a = Viewer(identity: devID, group: group, cols: cols, rows: rows)
    let b = Viewer(identity: devID, group: group, cols: cols, rows: rows)
    try a.connect(host, port, pinned: hostFP)
    try b.connect(host, port, pinned: hostFP)
    a.attach(fresh: true)
    check(a.sync(), "viewer A attached and matches the host")
    b.attach(fresh: true)
    check(b.sync(), "viewer B attached and matches the host")
    b.detach()
    a.type(input)
    Thread.sleep(forTimeInterval: 2)
    check(a.sync(), "viewer A followed the typed keys live")
    b.attach(fresh: true)
    check(b.sync(), "viewer B reattached into a fresh terminal and matches the host")
    _ = a.sync()
    let problems = a.queue.sync { b.queue.sync { Snapshot.diff(a.terminal, b.terminal) } }
    check(problems.isEmpty, "cell-by-cell: B equals A" + (problems.isEmpty ? "" : ":\n          " + problems.joined(separator: "\n          ")))
    print("        --- screen as B sees it ---")
    let text = b.queue.sync { Snapshot.screenText(b.terminal) }
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.isEmpty { print("        | " + line) }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
default:
    print("usage: Spike selftest [path-to-claude] | serve PORT CODE EXE [ARGS] | watch HOST PORT CODE KEYS")
}
