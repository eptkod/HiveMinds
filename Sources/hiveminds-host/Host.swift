import Foundation
import HiveMindsCore
import HiveMindsProtocol
import HiveMindsNet
#if canImport(Glibc)
import Glibc
#endif

/// `hiveminds-host serve`: runs this machine's agents until it's stopped, for paired devices on the local network
/// (docs/LINUX-HOST-SPEC.md, docs/HOST-PROTOCOL.md). Everything here runs on the main queue; each agent's
/// session has its own queue and reports back here.
final class Host {
    let paths: Paths
    let name: String
    private let port: Int
    private let listen: String?
    private var config: HostConfig
    private let agentFile: AgentFile
    private let records: AgentRecords
    private var tools = Tools()
    private var sessions: [UUID: AgentSession] = [:]
    private var followers: [UUID: [ControlConnection]] = [:]
    private var printed: [UUID: (AgentStatus, String)] = [:]
    private var trusting: Set<UUID> = []
    private var trustCheckPending: Set<UUID> = []
    private var control: ControlServer?
    private var lockFD: Int32 = -1
    private var signals: [DispatchSourceSignal] = []
    private let console = Console()
    private var audit: AuditLog!
    private var registry: DeviceRegistry!
    private var hub: RemoteHub?
    private var hostID = ""
    private var shuttingDown = false
    private var shutdownQuestion: UUID?
    private let started = Date()

    // Pairing: the code's expiry note, the owner question, and `hiveminds-host pair` windows.
    private var codeExpiry: DispatchWorkItem?
    private var ownerQuestion: (id: UUID, console: UUID?, answer: (Bool) -> Void)?
    private var pairWatchers: [ControlConnection] = []

    init(paths: Paths, name: String?, port: Int, listen: String?) throws {
        self.paths = paths
        self.port = port
        self.listen = listen
        try paths.prepare()
        config = try HostConfig.load(paths)
        self.name = name ?? config.name ?? Host.machineName()
        agentFile = try AgentFile(paths)
        records = AgentRecords(paths)
    }

    static func machineName() -> String {
        var buf = [CChar](repeating: 0, count: 256)
        gethostname(&buf, buf.count)
        let full = String(cString: buf)
        return full.split(separator: ".").first.map(String.init) ?? (full.isEmpty ? "hiveminds-host" : full)
    }

    var isShuttingDown: Bool { shuttingDown }

    // MARK: Running

    func run() throws -> Never {
        do {
            try startUp()
        } catch {
            console.restore()
            throw error
        }
        dispatchMain()
    }

    private func startUp() throws {
        try takeLock()
        HookSettings.write(paths.hookFiles, keyVariable: "HIVEMINDS_ANTHROPIC_KEY")
        tools = Tools.detect()
        // For tests: a stand-in for Claude Code (scripts/test-host.sh).
        if let fake = ProcessInfo.processInfo.environment["HIVEMINDS_HOST_CLAUDE"], !fake.isEmpty { tools.claude = fake }
        audit = AuditLog(paths.auditFile)
        registry = try DeviceRegistry(file: paths.devicesFile)
        for gone in registry.expire() { audit.write("device expired", device: gone.info, detail: "unused for 90 days") }
        hostID = try loadHostID()
        let identity = try Identity.loadOrCreate(in: paths.identityDir, commonName: "hiveminds-host \(hostID)")
        let hub = try RemoteHub(host: self, identity: identity, hostID: hostID, port: port, listen: listen, audit: audit,
                                registry: registry, hostName: name)
        hub.gate.askOwner = { [weak self] name, fp, answer in self?.askOwner(name, fp, answer) ?? answer(false) }
        hub.gate.ownerTimedOut = { [weak self] in self?.ownerDidntAnswer() }
        self.hub = hub
        control = try ControlServer(path: paths.controlSocket.path, queue: .main) { [weak self] c, request in
            self?.handle(request, from: c)
        }
        let addresses = try hub.start()
        audit.write("host started", detail: "listening on \(addresses.joined(separator: ", ")) port \(port)")
        watchSignals()
        console.onKey = { [weak self] key in
            if key == "p" || key == "P" { self?.showNewCode() }
        }
        printBanner(addresses, identity)
    }

    private func loadHostID() throws -> String {
        if let s = try? String(contentsOf: paths.hostIDFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           s.count == 16, s.allSatisfy(\.isHexDigit) {
            return s
        }
        let id = randomHexID()
        try writePrivate(Data((id + "\n").utf8), to: paths.hostIDFile)
        return id
    }

    private func takeLock() throws {
        let fd = open(paths.lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw HostError("Couldn't open \(paths.lockFile.path): \(String(cString: strerror(errno)))") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let other = (try? String(contentsOfFile: paths.lockFile.path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            close(fd)
            throw HostError("Another hiveminds-host is already running\(other.isEmpty ? "" : " (process \(other))"). Stop it first, or use `hiveminds-host status`.")
        }
        ftruncate(fd, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        lockFD = fd
    }

    static func display(_ address: String, _ port: Int) -> String {
        address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    private func printBanner(_ addresses: [String], _ identity: Identity) {
        // Loopback and link-local addresses work but aren't what someone types; show the others first.
        let lan = addresses.filter { !$0.hasPrefix("127.") && $0 != "::1" && !$0.lowercased().hasPrefix("fe80") && !$0.hasPrefix("169.254.") }
        let shown = (lan.isEmpty ? addresses : lan).map { Host.display($0, port) }
        if lan.isEmpty && listen == nil {
            say("HiveMinds host \"\(name)\" is running, but this machine isn't on a local network yet (only \(shown.joined(separator: ", "))). It starts listening as soon as it is.")
        } else {
            say("HiveMinds host \"\(name)\" is on the local network (\(shown.joined(separator: ", "))).")
        }
        say("  Fingerprint: \(Identity.display(identity.fingerprint))")
        let projects = config.projects.count
        say("  Projects: \(projects == 0 ? "none yet. Add one with: hiveminds-host projects add <folder>" : "\(projects) (hiveminds-host projects list)")")
        if let claude = tools.claude { say("  Claude Code: \(claude)") } else { say("  Claude Code isn't installed here, so agents can't start. Install it, run `claude` once to log in, then restart the host.") }
        if let problem = hub?.discoveryProblem {
            say("  Not announced on the network (\(problem)). Devices can still connect by address.")
        }
        say("  An agent can run any command this user can. Pair only devices you trust.")
        if console.isInteractive {
            showNewCode(intro: "To pair a device, open HiveMinds on it and pick this host.")
        } else {
            say("To pair a device, run `hiveminds-host pair` in a terminal on this machine.")
        }
        say("Agents run only while this does. Press Ctrl+C to stop.")
    }

    func say(_ line: String) {
        // A question waiting on the line: start a fresh line, then show the question again.
        if console.hasQuestion { console.write("\n") }
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // MARK: Pairing

    /// Shows a new pairing code here and in any `hiveminds-host pair` window.
    private func showNewCode(intro: String? = nil) {
        guard let hub, !shuttingDown else { return }
        let code = hub.gate.desk.newCode()
        say("\(intro.map { $0 + " " } ?? "")Pairing code: \(code.display) (valid 60 s, press p for a new one)")
        for w in pairWatchers { w.send(["event": "code", "code": code.display, "seconds": 60]) }
        codeExpiry?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let current = self.hub?.gate.desk.code, current.digits == code.digits, !current.used else { return }
            self.say("The pairing code expired. Press p for a new one.")
            for w in self.pairWatchers { w.send(["event": "expired"]) }
        }
        codeExpiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    /// A device proved it has the code: ask the owner, here and in any `pair` window; the first answer counts.
    private func askOwner(_ deviceName: String, _ fingerprint: String, _ answer: @escaping (Bool) -> Void) {
        codeExpiry?.cancel()
        let id = UUID()
        let prompt = "Allow \"\(deviceName)\" (fingerprint \(Identity.display(fingerprint))) to use this host? It will be able to run commands here. [y/N]"
        var questionID: UUID?
        if console.isInteractive {
            questionID = console.ask(prompt) { [weak self] yes in self?.ownerAnswered(id, yes, from: nil) }
        }
        ownerQuestion = (id, questionID, answer)
        for w in pairWatchers { w.send(["event": "question", "id": id.uuidString, "prompt": prompt]) }
        if !console.isInteractive && pairWatchers.isEmpty {
            say("\(Host.clock()) \"\(deviceName)\" wants to pair, but nobody can answer: run `hiveminds-host pair` to allow it.")
        }
    }

    private func ownerAnswered(_ id: UUID, _ yes: Bool, from watcher: ControlConnection?) {
        guard let q = ownerQuestion, q.id == id else { return }
        ownerQuestion = nil
        if let c = q.console, watcher != nil { console.withdraw(c, note: yes ? "Allowed from `hiveminds-host pair`." : "Not allowed (answered in `hiveminds-host pair`).") }
        for w in pairWatchers where w !== watcher { w.send(["event": "answered", "id": id.uuidString, "allowed": yes]) }
        if !yes { say("Not allowed.") }
        q.answer(yes)
    }

    private func ownerDidntAnswer() {
        guard let q = ownerQuestion else { return }
        ownerQuestion = nil
        if let c = q.console { console.withdraw(c, note: "No answer, so the device wasn't allowed.") }
        for w in pairWatchers { w.send(["event": "answered", "id": q.id.uuidString, "allowed": false]) }
    }

    // MARK: Stopping

    private func watchSignals() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in self?.received(signal: sig) }
            s.resume()
            signals.append(s)
        }
        // A write to an agent or a device that has just gone shouldn't take the host with it.
        signal(SIGPIPE, SIG_IGN)
    }

    private var running: [AgentSession] { sessions.values.filter(\.isRunning) }

    private func received(signal sig: Int32) {
        if sig != SIGINT {
            // systemctl stop, or the terminal closing: stop without asking.
            say(sig == SIGTERM ? "Stopping, as the system asked." : "The terminal closed. Stopping.")
            return shutDown(force: false, reason: "systemStop")
        }
        if shuttingDown || shutdownQuestion != nil {
            say("\nStopping now.")
            return shutDown(force: true, reason: "stopped")
        }
        let count = running.count
        guard count > 0, console.isInteractive else {
            say("")
            return shutDown(force: false, reason: "stopped")
        }
        console.write("\n")
        shutdownQuestion = console.ask("\(count) agent\(count == 1 ? " is" : "s are") running. Stop \(count == 1 ? "it" : "them") and shut down? [y/N]   (Ctrl+C again to force)") { [weak self] yes in
            guard let self else { return }
            self.shutdownQuestion = nil
            if yes { self.shutDown(force: false, reason: "stopped") } else { self.say("Carrying on.") }
        }
    }

    /// Tells connected devices, stops every agent (asking nicely first unless `force`), then exits.
    /// Nothing keeps running afterwards.
    private func shutDown(force: Bool, reason: String) {
        if shuttingDown && !force { return }
        if !shuttingDown {
            hub?.stop(reason: reason, message: reason == "systemStop" ? "\(name) was stopped by its system." : "\(name) was stopped.")
            audit?.write("host stopping", detail: reason == "systemStop" ? "asked by the system" : "Ctrl+C")
        }
        shuttingDown = true
        if let q = ownerQuestion { ownerQuestion = nil; q.answer(false) }
        console.cancelAll()
        let live = running
        if live.isEmpty { return exitNow() }
        if force {
            for s in live { s.forceStop() }
        } else {
            say("Stopping \(live.count) agent\(live.count == 1 ? "" : "s")…")
            for s in live { s.stop(grace: 3) }
        }
        let group = DispatchGroup()
        for s in live {
            group.enter()
            s.whenStopped { group.leave() }
        }
        group.notify(queue: .main) { [weak self] in self?.exitNow() }
        // If one won't go, don't wait for ever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self else { return }
            for s in self.running { s.forceStop() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.exitNow() }
        }
    }

    private var exited = false
    private func exitNow() {
        guard !exited else { return }
        exited = true
        hub?.shutDown()
        control?.shut()
        console.restore()
        if lockFD >= 0 { unlink(paths.lockFile.path); close(lockFD) }
        audit?.write("host stopped")
        say("The host has stopped.")
        exit(0)
    }

    // MARK: Agents (shared by the network and the local debug commands)

    func agent(_ id: UUID) -> Agent? { agentFile.agents.first { $0.id == id } }
    func allAgentIDs() -> [UUID] { agentFile.agents.map(\.id) }
    func project(_ id: UUID) -> Project? { config.projects.first { $0.id == id } }
    private func project(of agent: Agent) -> Project? { project(agent.projectID) }
    func session(_ id: UUID) -> AgentSession? {
        if let s = sessions[id] { return s }
        return agent(id).map { session(for: $0) }
    }

    func projectInfos() -> [ProjectInfo] {
        config.projects.filter { !$0.isHidden }.map { ProjectInfo(id: $0.id, name: $0.name, isGitRepo: $0.isGitRepo, repo: $0.repo) }
    }

    func agentInfo(_ id: UUID, viewers: [DeviceInfo], controller: DeviceInfo?) -> AgentInfo? {
        guard let a = agent(id) else { return nil }
        let s = sessions[id]
        let state = s?.state ?? LiveState()
        let size = s?.size ?? (cols: 120, rows: 40)
        return Host.info(a, state: state, running: s?.isRunning ?? false, size: size, startedBy: records.startedBy[id],
                         viewers: viewers, controller: controller)
    }

    static func info(_ a: Agent, state: LiveState, running: Bool, size: (cols: Int, rows: Int), startedBy: DeviceInfo?,
                     viewers: [DeviceInfo] = [], controller: DeviceInfo? = nil, endedAt: Date? = nil) -> AgentInfo {
        let ask: AskInfo? = switch state.ask?.kind {
        case .permission(let tool, let detail)?: .permission(tool: tool, detail: detail)
        case .questions(let q)?: .questions(q.map { QuestionInfo(header: $0.header, question: $0.question, options: $0.options, multiSelect: $0.multiSelect) })
        case .plan(let p)?: .plan(p)
        case nil: nil
        }
        return AgentInfo(id: a.id, projectId: a.projectID, title: a.title, provider: a.provider.rawValue, model: a.model,
                         effort: a.effort?.rawValue, access: a.access?.rawValue, branch: a.branch,
                         createdAt: a.createdAt.timeIntervalSince1970, startedBy: startedBy, status: state.status.rawValue,
                         activity: state.activity, ask: ask, running: running, cols: size.cols, rows: size.rows,
                         viewers: viewers, controller: controller, endedAt: endedAt?.timeIntervalSince1970)
    }

    func historyInfos() -> [AgentInfo] {
        records.history.map { Host.info($0.agent, state: LiveState(status: .asleep, activity: "Deleted"), running: false,
                                        size: (120, 40), startedBy: $0.startedBy, endedAt: $0.endedAt) }
    }

    private func context(for agent: Agent) -> (String) -> LaunchContext {
        let paths = self.paths
        return { exe in
            LaunchContext(executable: exe, baseEnvironment: Shell.environment,
                          claudeSettingsFile: paths.hookFiles.hooks.path,
                          eventsFile: paths.eventsDir.appendingPathComponent("\(agent.id.uuidString).jsonl").path,
                          statusFile: paths.statusDir.appendingPathComponent("\(agent.id.uuidString).json").path,
                          defaultAccess: .auto, meetingSeatsAcceptEdits: true)
        }
    }

    private func session(for agent: Agent) -> AgentSession {
        if let s = sessions[agent.id] { return s }
        let s = AgentSession(agent: agent)
        let id = agent.id
        s.observe { [weak self] event in
            DispatchQueue.main.async { self?.sessionEvent(id, event) }
        }
        sessions[id] = s
        return s
    }

    private func launch(_ agent: Agent) {
        session(for: agent).start(executable: tools.path(for: agent.provider), context: context(for: agent))
    }

    func createAgent(_ request: NewAgent, in project: Project, by device: DeviceInfo?, trust: Bool = false) async throws -> Agent {
        let agent = try await AgentFactory.create(request, in: project, git: tools.git)
        agentFile.put(agent)
        if let device { records.setStartedBy(agent.id, device) }
        if trust { trusting.insert(agent.id) }
        launch(agent)
        if AgentFactory.wantsGeneratedTitle(request), let s = sessions[agent.id] { askForTitle(s, request.trimmedTask) }
        hub?.agentChanged(agent.id)
        return agent
    }

    func startAgent(_ id: UUID, trust: Bool = false) {
        guard let a = agent(id), !(sessions[id]?.isRunning ?? false) else { return }
        if trust { trusting.insert(id) }
        launch(a)
    }

    func stopAgent(_ id: UUID) { sessions[id]?.stop() }

    func restartAgent(_ id: UUID, trust: Bool = false) {
        guard let a = agent(id) else { return }
        if trust { trusting.insert(id) }
        let s = session(for: a)
        s.stop()
        s.whenStopped { DispatchQueue.main.async { self.launch(self.agent(id) ?? a) } }
    }

    /// Stops and removes the agent. Its worktree goes too, unless it has changes that aren't committed; its branch
    /// always stays. Returns whether the folder was kept.
    func deleteAgent(_ id: UUID) async -> Bool {
        guard let a = agent(id) else { return false }
        if let s = sessions[id] {
            s.stop()
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in s.whenStopped { c.resume() } }
        }
        var kept = false
        if a.branch != nil, let git = tools.git, let p = project(of: a) {
            kept = !(await Shell.run(git, ["-C", p.path, "worktree", "remove", a.cwd])).ok
        }
        hub?.agentRemoved(id)
        sessions[id] = nil
        records.remember(a)
        agentFile.remove(id)
        try? FileManager.default.removeItem(at: paths.eventsDir.appendingPathComponent("\(id.uuidString).jsonl"))
        try? FileManager.default.removeItem(at: paths.statusDir.appendingPathComponent("\(id.uuidString).json"))
        return kept
    }

    func changes(_ id: UUID) async throws -> ChangeSet {
        guard let a = agent(id) else { throw CoreError("That agent isn't on this host any more.") }
        return try await Git.changes(git: tools.git, of: a, projectPath: project(of: a)?.path, transcripts: sessions[id]?.transcripts ?? [])
    }

    func diff(_ id: UUID, path: String, baseRef: String, untracked: Bool) async -> (lines: [DiffLine], cut: Bool) {
        guard let a = agent(id) else { return ([], false) }
        let set = ChangeSet(base: "", baseRef: baseRef, files: [])
        return await Git.diff(git: tools.git, cwd: a.cwd, file: ChangedFile(path: path, added: nil, removed: nil, untracked: untracked), against: set)
    }

    private func sessionEvent(_ id: UUID, _ event: AgentSession.Event) {
        guard let s = sessions[id] else { return }
        switch event {
        case .state(let state):
            let last = printed[id]
            if last?.0 != state.status || last?.1 != state.activity {
                printed[id] = (state.status, state.activity)
                let title = agent(id)?.title ?? "Agent"
                say("\(Host.clock()) \(title) · \(state.status.label)\(state.activity.isEmpty ? "" : " · \(state.activity)")")
            }
            for c in followers[id] ?? [] { c.send(Host.describe(state, id: id)) }
            if state.status != .starting { trusting.remove(id) }
            hub?.agentChanged(id)
        case .agent(let agent):
            agentFile.put(agent)
            hub?.agentChanged(id)
        case .output:
            if trusting.contains(id) { checkTrust(id, s) }
        case .wantsTitle(let prompt):
            askForTitle(s, prompt)
        case .turnEnded, .resized:
            break
        case .exited:
            for c in followers[id] ?? [] { c.send(["event": "exited", "id": id.uuidString]) }
            hub?.agentChanged(id)
        }
    }

    private func askForTitle(_ s: AgentSession, _ prompt: String) {
        guard let claude = tools.claude else { return }
        let cwd = paths.data.path
        Task {
            if let title = await ChatTitle.ask(claude: claude, prompt: prompt, cwd: cwd) { s.setTitle(title) }
        }
    }

    /// Debug runs only: answers Claude Code's "trust this folder?" by looking at the screen, once it settles.
    private func checkTrust(_ id: UUID, _ s: AgentSession) {
        guard !trustCheckPending.contains(id) else { return }
        trustCheckPending.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            self.trustCheckPending.remove(id)
            guard self.trusting.contains(id) else { return }
            let screen = s.screenText()
            guard screen.contains("trust this folder") else { return }
            let selected = screen.split(separator: "\n").first { $0.contains("❯") }
            s.input(Array((selected?.contains("Yes, I trust") == true ? "\r" : "\u{1b}[B").utf8))
        }
    }

    static func describe(_ state: LiveState, id: UUID) -> [String: Any] {
        var out: [String: Any] = ["event": "state", "id": id.uuidString, "status": state.status.rawValue, "activity": state.activity]
        switch state.ask?.kind {
        case .permission(let tool, let detail)?: out["ask"] = ["kind": "permission", "tool": tool, "detail": detail]
        case .questions(let q)?: out["ask"] = ["kind": "questions", "questions": q.map { ["question": $0.question, "options": $0.options] }]
        case .plan(let plan)?: out["ask"] = ["kind": "plan", "plan": plan]
        case nil: break
        }
        return out
    }

    // MARK: Requests over the control socket (this machine only)

    private func handle(_ r: [String: Any], from c: ControlConnection) {
        let command = r["command"] as? String ?? ""
        func agentID() -> UUID? { (r["id"] as? String).flatMap { id in agentFile.agents.first { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }?.id } }
        func fail(_ message: String) { c.finish(["error": message]) }
        switch command {
        case "status":
            c.finish(statusReport())
        case "reload-config":
            do {
                config = try HostConfig.load(paths)
                hub?.projectsChanged()
                c.finish(["ok": true])
            } catch { fail("\(error)") }
        case "devices":
            c.finish(["devices": registry.devices.map(Host.describe(device:)), "connected": hub?.connectedDevices.map(\.id) ?? []])
        case "revoke":
            let gone = registry.revoke(r["device"] as? String ?? "")
            guard !gone.isEmpty else { return fail("No paired device is called that. See `hiveminds-host devices list`.") }
            for d in gone { audit.write("revoked", device: d.info) }
            hub?.disconnect(deviceIDs: Set(gone.map(\.id)))
            c.finish(["revoked": gone.map(\.name)])
        case "pair":
            // `hiveminds-host pair`: shows codes and asks the owner here too.
            pairWatchers.append(c)
            c.onClose.append { [weak self] in self?.pairWatchers.removeAll { $0 === c } }
            c.send(["event": "hello", "name": name])
            if let q = ownerQuestion {
                c.send(["event": "question", "id": q.id.uuidString, "prompt": "A device is waiting to pair. Allow it? [y/N]"])
            } else {
                showNewCode()
            }
        case "pair-new-code":
            showNewCode()
            c.finish(["ok": true, "code": hub?.gate.desk.code?.digits ?? ""])
        case "pair-answer":
            // Without an id: whatever device is waiting now.
            guard let id = (r["id"] as? String).flatMap(UUID.init(uuidString:)) ?? ownerQuestion?.id else { return fail("No device is waiting to pair.") }
            ownerAnswered(id, r["allowed"] as? Bool == true, from: c)
            c.send(["event": "answered", "id": id.uuidString, "allowed": r["allowed"] as? Bool == true])
        case "start":
            guard !shuttingDown else { return fail("The host is shutting down.") }
            guard let p = (r["project"] as? String).flatMap({ config.project(matching: $0) }) else {
                return fail("That project isn't registered on this host. See `hiveminds-host projects list`.")
            }
            let request = NewAgent(provider: Provider(rawValue: r["provider"] as? String ?? "") ?? .claude,
                                   model: r["model"] as? String ?? "default",
                                   effort: Effort(rawValue: r["effort"] as? String ?? "") ?? .medium,
                                   access: Access(rawValue: r["access"] as? String ?? "") ?? .auto,
                                   planMode: r["plan"] as? Bool ?? false, task: r["task"] as? String ?? "",
                                   ownBranch: r["ownBranch"] as? Bool ?? false)
            Task { @MainActor in
                do {
                    let agent = try await self.createAgent(request, in: p, by: nil, trust: r["trust"] as? Bool == true)
                    self.audit.write("created agent", agent: agent.id, detail: "from this machine (debug)")
                    c.finish(["ok": true, "id": agent.id.uuidString, "cwd": agent.cwd, "branch": agent.branch as Any])
                } catch {
                    fail(error.localizedDescription)
                }
            }
        case "restart":
            guard let id = agentID() else { return fail("No such agent.") }
            restartAgent(id, trust: r["trust"] as? Bool == true)
            c.finish(["ok": true, "id": id.uuidString])
        case "stop":
            guard let id = agentID() else { return fail("No such agent.") }
            stopAgent(id)
            c.finish(["ok": true])
        case "follow":
            guard let id = agentID(), let s = sessions[id] else { return fail("That agent isn't running on this host.") }
            followers[id, default: []].append(c)
            c.onClose.append { [weak self] in self?.followers[id]?.removeAll { $0 === c } }
            c.send(Host.describe(s.state, id: id))
        case "screen":
            guard let id = agentID(), let s = sessions[id] else { return fail("That agent isn't running on this host.") }
            c.finish(["screen": s.screenText(), "menu": s.menuOptions().map { "\($0.number). \($0.label)" }])
        case "type":
            guard let id = agentID(), let s = sessions[id], let text = r["text"] as? String else { return fail("No such agent, or no text.") }
            s.type(text)
            c.finish(["ok": true])
        case "keys":
            guard let id = agentID(), let s = sessions[id], let keys = r["keys"] as? [String] else { return fail("No such agent, or no keys.") }
            s.press(keys)
            c.finish(["ok": true])
        case "respond":
            guard let id = agentID(), let s = sessions[id] else { return fail("That agent isn't running on this host.") }
            let action: PromptAction
            switch r["action"] as? String {
            case "allow": action = .allow
            case "decline": action = .decline
            case "approve": action = .approvePlan
            case "keep-planning": action = .keepPlanning(r["text"] as? String ?? "")
            default: return fail("Say allow, decline, approve or keep-planning.")
            }
            s.respond(action) { response in
                DispatchQueue.main.async {
                    switch response {
                    case .press(let keys, _, let activity): c.finish(["ok": true, "keys": keys, "activity": activity])
                    case .planChoicesNotFound: fail("Couldn't find the plan's choices on its screen.")
                    case .nothing: fail("It isn't asking that.")
                    }
                }
            }
        case "delete":
            guard let id = agentID() else { return fail("No such agent.") }
            Task { @MainActor in
                let kept = await self.deleteAgent(id)
                c.finish(["ok": true, "keptFolder": kept])
            }
        default:
            fail("This host doesn't know the command \"\(command)\".")
        }
    }

    static func describe(device d: PairedDevice) -> [String: Any] {
        ["id": d.id, "name": d.name, "fingerprint": Identity.display(d.fingerprint),
         "pairedAt": Int(d.pairedAt.timeIntervalSince1970), "lastUsed": Int(d.lastUsed.timeIntervalSince1970)]
    }

    private func statusReport() -> [String: Any] {
        let agents: [[String: Any]] = agentFile.agents.map { a in
            let s = sessions[a.id]
            let state = s?.state ?? LiveState()
            return ["id": a.id.uuidString, "title": a.title, "project": project(of: a)?.name ?? "(removed project)",
                    "status": state.status.rawValue, "activity": state.activity, "running": s?.isRunning ?? false,
                    "branch": a.branch as Any]
        }
        return ["name": name, "pid": Int(getpid()), "version": hostVersion, "since": Int(started.timeIntervalSince1970),
                "projects": config.projects.map { ["name": $0.name, "path": $0.path] }, "agents": agents,
                "addresses": hub?.server.addresses.map { Host.display($0, port) } ?? [],
                "fingerprint": hub.map { Identity.display($0.identity.fingerprint) } ?? "",
                "hostId": hostID, "announced": hub?.discoveryProblem == nil,
                "devices": hub?.connectedDevices.map(\.name) ?? []]
    }
}

/// Who started each agent, and the agents that were deleted (for `history`). Kept beside agents.json.
final class AgentRecords {
    struct Past: Codable {
        var agent: Agent
        var startedBy: DeviceInfo?
        var endedAt: Date
    }
    private let ownersFile: URL
    private let historyFile: URL
    private(set) var startedBy: [UUID: DeviceInfo] = [:]
    private(set) var history: [Past] = []

    init(_ paths: Paths) {
        ownersFile = paths.data.appendingPathComponent("started-by.json")
        historyFile = paths.data.appendingPathComponent("history.json")
        startedBy = (try? JSONDecoder().decode([UUID: DeviceInfo].self, from: Data(contentsOf: ownersFile))) ?? [:]
        history = (try? JSONDecoder().decode([Past].self, from: Data(contentsOf: historyFile))) ?? []
    }

    func setStartedBy(_ id: UUID, _ device: DeviceInfo) {
        startedBy[id] = device
        save(startedBy, to: ownersFile)
    }

    /// Keeps a deleted agent in the history (the newest 200).
    func remember(_ agent: Agent) {
        history.insert(Past(agent: agent, startedBy: startedBy[agent.id], endedAt: Date()), at: 0)
        if history.count > 200 { history.removeLast(history.count - 200) }
        startedBy[agent.id] = nil
        save(history, to: historyFile)
        save(startedBy, to: ownersFile)
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? e.encode(value) { try? writePrivate(data, to: url) }
    }
}
