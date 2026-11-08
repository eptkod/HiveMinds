#if DEBUG
import AppKit
import HiveMindsCore
import HiveMindsProtocol

/// Debug builds only: the app as a client of HiveMinds Host, end to end, driven by `scripts/test-app-remote.sh`.
/// Run with scratch `HIVEMINDS_SUPPORT_DIR` and `HIVEMINDS_HOSTS_FILE`, so nothing touches the real app's data or Keychain.
/// `HIVEMINDS_TEST_REMOTE=<address:port>` and `HIVEMINDS_TEST_REMOTE_PHASE`:
/// - `pair` (with `HIVEMINDS_TEST_REMOTE_CODE`): pairs, sees the host's projects, starts an agent on "demo", watches
///   its terminal, takes control, types, is asked permission, sees another device take over and is refused, takes
///   over again, allows, reads the changes, then quits with the agent left running.
/// - `again`: comes back, finds the agent still there, deletes it, finds it in the host's history, then waits for
///   the host to stop and says what the app shows.
/// Prints `REMOTE-…` lines; the script waits on them. `REMOTE-FAIL` (exit 1) or `REMOTE-TIMEOUT` (exit 2) on a problem.
@MainActor
enum DebugRemoteTest {
    static func run(store: AppStore, target: String) {
        let env = ProcessInfo.processInfo.environment
        let parts = target.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1]) else { log("REMOTE-FAIL bad address \(target)"); exit(1) }
        let address = String(parts[0])
        Task {
            switch env["HIVEMINDS_TEST_REMOTE_PHASE"] ?? "pair" {
            case "pair": await pair(store: store, address: address, port: port, code: env["HIVEMINDS_TEST_REMOTE_CODE"] ?? "")
            case "again": await again(store: store)
            default: log("REMOTE-FAIL unknown phase"); exit(1)
            }
        }
    }

    private static func log(_ s: String) { print(s); fflush(stdout) }

    /// Saves a capture of the window to `HIVEMINDS_TEST_REMOTE_SNAP-<name>.png`, if that's set, after `show` and a moment to draw.
    private static func snap(_ name: String, _ show: @MainActor () -> Void = {}) async {
        guard let prefix = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_REMOTE_SNAP"] else { return }
        show()
        try? await Task.sleep(for: .seconds(1.2))
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "HiveMinds" }) ?? NSApp.windows.first(where: \.isVisible),
              let image = DebugSnapshot.ownWindowImage(window.attachedSheet ?? window),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
    }

    /// Waits up to `seconds` for `ok`, checking every 0.2 s; times out the run if it never happens.
    private static func wait(_ what: String, _ seconds: Double = 20, _ ok: @MainActor () -> Bool) async {
        for _ in 0..<Int(seconds * 5) {
            if ok() { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
        log("REMOTE-TIMEOUT waiting for \(what)")
        exit(2)
    }

    /// Waits for the script to create a file (it does that after acting as the other device).
    private static func waitForSignal(_ name: String) async {
        guard let dir = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_REMOTE_SIGNALS"] else { return }
        let path = URL(fileURLWithPath: dir).appendingPathComponent(name).path
        await wait("signal \(name)", 60) { FileManager.default.fileExists(atPath: path) }
    }

    private static func pair(store: AppStore, address: String, port: Int, code: String) async {
        store.hosts.beginPairing(address: address, port: port)
        await wait("the code prompt") { if case .needsCode? = store.hosts.pairing?.step { true } else { false } }
        await snap("pairing")
        log("REMOTE-CODE-ASKED fingerprint \(store.hosts.pairing?.fingerprint ?? "")")
        store.hosts.pairing?.submit(code: code)
        await wait("the owner", 30) { if case .paired? = store.hosts.pairing?.step { true } else { false } }
        store.hosts.pairing = nil
        guard let host = store.hosts.hosts.first else { log("REMOTE-FAIL no host after pairing"); exit(1) }
        log("REMOTE-PAIRED \(host.name)")
        await wait("connected") { host.status.isConnected && !store.shownProjects(on: host).isEmpty }
        log("REMOTE-CONNECTED projects=\(store.shownProjects(on: host).map(\.name).joined(separator: ","))")
        guard let project = store.shownProjects(on: host).first(where: { $0.name == "demo" }) else { log("REMOTE-FAIL no demo project"); exit(1) }

        // Start an agent there, the way the New Agent sheet does.
        do {
            try await store.createAgent(projectID: project.id, provider: .claude, model: "haiku", role: "", task: "make hello", ownBranch: true)
        } catch { log("REMOTE-FAIL create: \(error.localizedDescription)"); exit(1) }
        guard let agent = store.agents.last(where: { store.isRemote($0.id) }) else { log("REMOTE-FAIL no agent"); exit(1) }
        let id = agent.id
        await wait("done") { store.state(id).status == .done }
        log("REMOTE-DONE \(id.uuidString) branch=\(store.agent(id)?.branch ?? "-") startedBy=\(store.remoteInfo(id)?.startedBy?.name ?? "?")")

        // Its terminal: the snapshot shows what happened before it was opened.
        let view = RemoteTerminals.shared.view(for: agent)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        await wait("the screen") { screen(view).contains("DID: make hello") }
        log("REMOTE-SCREEN \(view.cols)x\(view.rows)")

        // Take control: the agent's terminal takes this view's size.
        store.takeControl(id)
        await wait("control") { store.isController(of: id) }
        await wait("the resize") { view.cols == view.naturalSize().cols }
        log("REMOTE-CONTROLLER \(view.cols)x\(view.rows)")
        log("REMOTE-WATCHERS \(store.watchers(of: id).map(\.name).joined(separator: ","))")

        // Type a message; it asks permission.
        store.sendInput(id, "please ask permission")
        await wait("the permission prompt") { if case .permission? = store.state(id).ask?.kind { true } else { false } }
        log("REMOTE-ASKED \(store.state(id).status.rawValue)")
        await snap("sidebar") { store.mode = .agents; store.selection = .project(project.id) }
        await snap("agent-asking") { store.selection = .agent(id) }
        await snap("overview") { store.selection = .overview }
        store.selection = .agent(id)

        // The other device takes over: this Mac sees it and can't answer until it takes over again.
        log("REMOTE-WAITING-FOR-TAKEOVER")
        await waitForSignal("took-over")
        await wait("the other controller") { store.otherController(of: id) != nil }
        log("REMOTE-OTHER-CONTROLLER \(store.otherController(of: id)?.name ?? "")")
        await snap("agent-other-typing")
        store.warning = nil
        store.allow(id)
        await wait("the refusal") { store.warning != nil }
        log("REMOTE-REFUSED \(store.warning ?? "")")
        store.takeControl(id)
        await wait("control again") { store.isController(of: id) }
        store.allow(id)
        await wait("the answer") { store.state(id).ask == nil && screen(view).contains("KEY 1") }
        await wait("done again") { store.state(id).status == .done }
        log("REMOTE-ALLOWED \(store.state(id).status.rawValue)")

        // Changes come from the host.
        do {
            let changes = try await store.changes(of: store.agent(id)!)
            log("REMOTE-CHANGES \(changes.files.map(\.path).sorted().joined(separator: ","))")
            if let file = changes.files.first(where: { $0.path == "hello.txt" }) {
                let diff = await store.diff(of: store.agent(id)!, file: file, against: changes)
                log("REMOTE-DIFF \(diff.lines.count) lines")
            }
        } catch { log("REMOTE-FAIL changes: \(error.localizedDescription)"); exit(1) }

        // Quitting leaves the host's agent running.
        log("REMOTE-QUIT")
        NSApp.terminate(nil)
    }

    private static func again(store: AppStore) async {
        await wait("the host") { store.hosts.hosts.first?.status.isConnected == true }
        guard let host = store.hosts.hosts.first else { exit(1) }
        await wait("the agent") { store.agents.contains { store.isRemote($0.id) } }
        let agent = store.agents.first { store.isRemote($0.id) }!
        log("REMOTE-RESTORED \(agent.id.uuidString) \(store.state(agent.id).status.rawValue) local=\(store.agents.filter { !store.isRemote($0.id) }.count)")
        await store.deleteAgent(agent)
        await wait("it to go") { store.agent(agent.id) == nil }
        let past = await store.remoteHistory(host)
        log("REMOTE-HISTORY \(past.contains { $0.id == agent.id } ? "has it" : "missing")")
        await snap("history") { store.mode = .agents; store.selection = .history }
        log("REMOTE-WAITING-FOR-STOP")
        await wait("the host to stop", 30) { if case .stopped = host.status { true } else { false } }
        log("REMOTE-HOST-STOPPED \(host.status.label)")
        await snap("host-stopped") { store.mode = .agents; store.selection = .overview }
        exit(0)
    }

    private static func screen(_ view: RemoteTerminalContainer) -> String {
        TerminalSnapshot.screenText(view.term.getTerminal())
    }
}
#endif
