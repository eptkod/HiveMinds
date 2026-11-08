import Foundation
import HiveMindsCore
import HiveMindsProtocol
import HiveMindsNet

/// The host's network side (docs/HOST-PROTOCOL.md): listens on private addresses, announces itself, lets paired
/// devices in through `HostGate`, and serves their requests. Everything here runs on the main queue.
final class RemoteHub {
    private unowned let host: Host
    let identity: Identity
    let hostID: String
    let server: HostServer
    let gate: HostGate
    private let audit: AuditLog
    private let port: Int
    private let fixedListen: String?
    private var announcer: Announcer?
    private var addressWatch: AddressWatch?
    private(set) var discoveryProblem: String?
    private var sessions: [UUID: Session] = [:]

    /// Who's watching each agent: peer id → the token of its attach.
    private var viewers: [UUID: [UUID: UUID]] = [:]
    private struct Control {
        var peer: UUID
        var device: DeviceInfo
        var release: DispatchWorkItem
    }
    private var controllers: [UUID: Control] = [:]

    init(host: Host, identity: Identity, hostID: String, port: Int, listen: String?, audit: AuditLog,
         registry: DeviceRegistry, hostName: String) throws {
        self.host = host
        self.identity = identity
        self.hostID = hostID
        self.port = port
        fixedListen = listen
        self.audit = audit
        server = try HostServer(identity: identity, queue: .main)
        gate = HostGate(server: server, registry: registry, desk: PairingDesk(hostFingerprint: identity.fingerprint),
                        hostID: hostID, hostName: hostName, hostVersion: hostVersion, queue: .main)
        gate.onEvent = { [weak self] e in self?.record(e) }
        gate.onSession = { [weak self] s in self?.admit(s) }
    }

    // MARK: Listening and discovery

    /// Starts listening (and announcing). Returns the addresses it's listening on.
    func start() throws -> [String] {
        if let fixed = fixedListen {
            do { try server.listen(on: fixed, port: port) } catch { throw bindError(fixed, error) }
        } else {
            try syncAddresses(initial: true)
            addressWatch = AddressWatch(queue: .main) { [weak self] in try? self?.syncAddresses(initial: false) }
        }
        do {
            announcer = try Announcer(hostID: hostID, port: port, queue: .main)
        } catch {
            discoveryProblem = "\(error)"
        }
        return server.addresses
    }

    private func bindError(_ address: String, _ error: Error) -> HostError {
        let text = "\(error)"
        if text.contains("in use") || text.contains("EADDRINUSE") || text.contains("errno: 48") || text.contains("errno: 98") {
            return HostError("Port \(port) is in use by another program. Pick another with --port.")
        }
        return HostError("Couldn't listen on \(address):\(port): \(text)")
    }

    /// Listens on every private address this machine has now, and stops listening on ones it lost.
    private func syncAddresses(initial: Bool) throws {
        let wanted = Set(PrivateAddress.local().map(\.address))
        let current = Set(server.addresses)
        for gone in current.subtracting(wanted) {
            server.stopListening(on: gone)
            host.say("\(Host.clock()) No longer listening on \(gone) (that address went away).")
        }
        for new in wanted.subtracting(current).sorted() {
            do {
                try server.listen(on: new, port: port)
                if !initial { host.say("\(Host.clock()) Now listening on \(Host.display(new, port))") }
            } catch {
                // An address that can't be used (a link-local one in a bad state, say) mustn't stop the rest,
                // but a port someone else holds must be said at start.
                if initial, !new.contains(":") || new == "::1" { throw bindError(new, error) }
            }
        }
    }

    func stop(reason: String, message: String) {
        gate.closing = true
        for s in sessions.values { s.send(.event(.hostStopping(reason: reason, message: message))) }
        announcer?.stop()
        announcer = nil
    }

    func shutDown() {
        for s in sessions.values { s.close() }
        server.shutDown()
    }

    var connectedDevices: [DeviceInfo] { sessions.values.map(\.device.info) }

    /// Closes the connections of these (revoked) devices.
    func disconnect(deviceIDs: Set<String>) { gate.disconnect(deviceIDs: deviceIDs) }

    // MARK: Audit

    private func record(_ e: GateEvent) {
        switch e {
        case .refused(let address, let reason): audit.write("refused", address: address, detail: reason)
        case .connected(let address): audit.write("connected", address: address)
        case .tokenRejected(let address, let name): audit.write("token refused", address: address, detail: "said it was \"\(name)\"")
        case .incompatible(let address, let theirs): audit.write("wrong protocol version", address: address, detail: "theirs \(theirs)")
        case .pairingStarted(let address, let name): audit.write("pairing started", address: address, detail: "\"\(name)\"")
        case .wrongCode(let address, let name, let left): audit.write("wrong pairing code", address: address, detail: "\"\(name)\", \(left) tries left")
        case .paired(let d, let address):
            audit.write("paired", device: d.info, address: address, detail: "fingerprint \(Identity.display(d.fingerprint))")
            host.say("\(Host.clock()) Paired \"\(d.name)\".")
        case .pairingNotAllowed(let address, let name): audit.write("pairing not allowed", address: address, detail: "\"\(name)\"")
        case .authenticated(let d, let address):
            audit.write("signed in", device: d.info, address: address)
            host.say("\(Host.clock()) \"\(d.name)\" connected.")
        case .closed(let d, let address):
            if let d {
                audit.write("disconnected", device: d.info, address: address)
                host.say("\(Host.clock()) \"\(d.name)\" disconnected.")
            }
        }
    }

    // MARK: Sessions

    private func admit(_ s: Session) {
        sessions[s.peer.id] = s
        s.onRequest = { [weak self, weak s] id, r in
            guard let self, let s else { return }
            self.handle(s, id, r)
        }
        s.onFrame = { [weak self, weak s] f in
            guard let self, let s, f.kind == .input else { return }
            self.typed(s, f.agentID, f.bytes)
        }
        s.onClose = { [weak self, weak s] in
            guard let self, let s else { return }
            self.left(s)
        }
    }

    private func left(_ s: Session) {
        sessions[s.peer.id] = nil
        for agent in Array(viewers.keys) where viewers[agent]?[s.peer.id] != nil {
            removeViewer(s.peer.id, from: agent)
        }
        for (agent, c) in controllers where c.peer == s.peer.id { release(agent) }
    }

    func broadcast(_ e: Event) {
        for s in sessions.values { s.send(.event(e)) }
    }

    /// Something about an agent changed: everyone gets its new state.
    func agentChanged(_ id: UUID) {
        guard !sessions.isEmpty, let info = host.agentInfo(id, viewers: viewerDevices(id), controller: controllers[id]?.device) else { return }
        broadcast(.agentUpdated(info))
    }

    func agentRemoved(_ id: UUID) {
        for (peer, token) in viewers[id] ?? [:] {
            host.session(id)?.stopObserving(token)
            sessions[peer]?.send(.event(.detached(agentId: id, reason: "deleted")))
        }
        viewers[id] = nil
        controllers[id]?.release.cancel()
        controllers[id] = nil
        broadcast(.agentRemoved(id))
    }

    func projectsChanged() { broadcast(.projectsChanged(host.projectInfos())) }

    private func viewerDevices(_ id: UUID) -> [DeviceInfo] {
        (viewers[id] ?? [:]).keys.compactMap { sessions[$0]?.device.info }.sorted { $0.name < $1.name }
    }

    // MARK: Requests

    private func handle(_ s: Session, _ id: String, _ r: Request) {
        let device = s.device.info
        func reply(_ build: (inout Reply) -> Void = { _ in }) {
            var x = Reply()
            build(&x)
            s.reply(id, x)
        }
        func fail(_ code: String, _ message: String, controller: DeviceInfo? = nil) {
            s.fail(id, ErrorInfo(code, message, controller: controller))
        }
        func agentInfo(_ agentID: UUID) -> AgentInfo? {
            host.agentInfo(agentID, viewers: viewerDevices(agentID), controller: controllers[agentID]?.device)
        }
        if let agentID = r.agentID, host.agent(agentID) == nil {
            return fail("noSuchAgent", "That agent isn't on this host any more.")
        }
        if host.isShuttingDown, case .createAgent = r { return fail("shuttingDown", "The host is shutting down.") }

        switch r {
        case .listProjects:
            reply { $0.projects = host.projectInfos() }
        case .listAgents:
            reply { $0.agents = host.allAgentIDs().compactMap { agentInfo($0) } }
        case .history:
            reply { $0.agents = host.historyInfos() }
        case .createAgent(let c):
            guard let project = host.project(c.projectId) else { return fail("noSuchProject", "That project isn't on this host any more.") }
            let request = NewAgent(provider: Provider(rawValue: c.provider) ?? .claude, model: c.model,
                                   effort: Effort(rawValue: c.effort) ?? .medium, access: Access(rawValue: c.access) ?? .auto,
                                   planMode: c.planMode, role: c.role, task: c.task, ownBranch: c.ownBranch)
            Task { @MainActor in
                do {
                    let agent = try await self.host.createAgent(request, in: project, by: device)
                    self.audit.write("created agent", device: device, agent: agent.id, detail: "in \(project.name)\(agent.branch.map { " on \($0)" } ?? "")")
                    reply { $0.agent = agentInfo(agent.id) }
                } catch {
                    fail("cantCreate", error.localizedDescription)
                }
            }
        case .startAgent(let a):
            audit.write("started agent", device: device, agent: a.agentId)
            host.startAgent(a.agentId)
            reply { $0.agent = agentInfo(a.agentId) }
        case .stopAgent(let a):
            audit.write("stopped agent", device: device, agent: a.agentId)
            host.stopAgent(a.agentId)
            reply { $0.agent = agentInfo(a.agentId) }
        case .restartAgent(let a):
            audit.write("restarted agent", device: device, agent: a.agentId)
            host.restartAgent(a.agentId)
            reply { $0.agent = agentInfo(a.agentId) }
        case .deleteAgent(let a):
            audit.write("deleted agent", device: device, agent: a.agentId)
            Task { @MainActor in
                let kept = await self.host.deleteAgent(a.agentId)
                reply { $0.keptFolder = kept }
            }
        case .attach(let a):
            guard let session = host.session(a.agentId) else { return fail("noSuchAgent", "That agent isn't on this host any more.") }
            if let old = viewers[a.agentId]?[s.peer.id] { session.stopObserving(old) }
            let size = session.size
            reply { $0.cols = size.cols; $0.rows = size.rows }
            let agentID = a.agentId
            // The snapshot and everything after it, in order, straight from the agent's queue.
            let token = session.attach(snapshot: { [weak s] bytes, _, _ in
                s?.send(frame: TerminalFrame(.snapshot, agentID, bytes))
            }) { [weak s] event in
                guard let s else { return }
                switch event {
                case .output(let bytes): s.send(frame: TerminalFrame(.output, agentID, bytes))
                case .resized(let cols, let rows, let snapshot):
                    s.send(.event(.resized(agentId: agentID, cols: cols, rows: rows)))
                    s.send(frame: TerminalFrame(.snapshot, agentID, snapshot))
                default: break
                }
            }
            viewers[agentID, default: [:]][s.peer.id] = token
            viewersChanged(agentID)
        case .detach(let a):
            removeViewer(s.peer.id, from: a.agentId)
            reply()
        case .takeControl(let t):
            let previous = controllers[t.agentId]
            if previous?.peer != s.peer.id {
                audit.write("took control", device: device, agent: t.agentId, detail: previous.map { "from \"\($0.device.name)\"" })
            }
            control(t.agentId, by: s, tookOverFrom: previous?.peer == s.peer.id ? nil : previous?.device)
            host.session(t.agentId)?.resize(cols: t.cols, rows: t.rows)
            reply { $0.agent = agentInfo(t.agentId) }
        case .resize(let t):
            guard controllers[t.agentId]?.peer == s.peer.id else {
                return fail("notController", "Only the person typing can change its size.", controller: controllers[t.agentId]?.device)
            }
            host.session(t.agentId)?.resize(cols: t.cols, rows: t.rows)
            reply()
        case .typeText(let t):
            guard mayType(s, t.agentId) else {
                return fail("notController", "\(controllers[t.agentId]?.device.name ?? "Someone") is typing in this agent. Take over to type.",
                            controller: controllers[t.agentId]?.device)
            }
            host.session(t.agentId)?.type(t.text)
            reply()
        case .answer(let a):
            guard mayType(s, a.agentId) else {
                return fail("notController", "\(controllers[a.agentId]?.device.name ?? "Someone") is typing in this agent. Take over to answer.",
                            controller: controllers[a.agentId]?.device)
            }
            let action: PromptAction
            switch a.action {
            case "allow": action = .allow
            case "decline": action = .decline
            case "approvePlan": action = .approvePlan
            case "keepPlanning": action = .keepPlanning(a.feedback ?? "")
            case "answer":
                action = .answer((a.answers ?? []).map { if case .option(let n) = $0 { .option(n) } else if case .text(let t) = $0 { .text(t) } else { .text("") } })
            default: return fail("badRequest", "Answer with allow, decline, approvePlan, keepPlanning or answer.")
            }
            host.session(a.agentId)?.respond(action) { [weak self] response in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch response {
                    case .press(_, _, let activity):
                        self.audit.write("answered", device: device, agent: a.agentId, detail: a.action)
                        self.broadcast(.promptResolved(agentId: a.agentId, by: device, activity: activity))
                        reply { $0.activity = activity }
                    case .planChoicesNotFound: fail("planChoicesNotFound", "Couldn't find the plan's choices on its screen. Open its terminal to answer there.")
                    case .nothing: fail("notAsking", "It isn't asking that any more (someone may have answered already).")
                    }
                }
            }
        case .changes(let a):
            Task { @MainActor in
                do {
                    let set = try await self.host.changes(a.agentId)
                    reply {
                        $0.base = set.base
                        $0.baseRef = set.baseRef
                        $0.onlyItsOwn = set.onlyItsOwn
                        $0.files = set.files.map { ChangedFileInfo(path: $0.path, added: $0.added, removed: $0.removed, untracked: $0.untracked) }
                    }
                } catch {
                    fail("cantRead", error.localizedDescription)
                }
            }
        case .diff(let d):
            Task { @MainActor in
                let r = await self.host.diff(d.agentId, path: d.path, baseRef: d.baseRef, untracked: d.untracked)
                reply {
                    $0.lines = r.lines.map { DiffLineInfo(kind: "\($0.kind)", text: $0.text) }
                    $0.cut = r.cut
                }
            }
        }
    }

    // MARK: Watching and typing

    private func removeViewer(_ peer: UUID, from agent: UUID) {
        guard let token = viewers[agent]?.removeValue(forKey: peer) else { return }
        host.session(agent)?.stopObserving(token)
        if viewers[agent]?.isEmpty == true { viewers[agent] = nil }
        if controllers[agent]?.peer == peer { release(agent) }
        viewersChanged(agent)
    }

    private func viewersChanged(_ agent: UUID) {
        broadcast(.viewers(agentId: agent, viewers: viewerDevices(agent)))
        agentChanged(agent)
    }

    /// Whether this device may type into the agent now; makes it the controller when nobody is.
    private func mayType(_ s: Session, _ agent: UUID) -> Bool {
        if let c = controllers[agent], c.peer != s.peer.id { return false }
        if controllers[agent] == nil {
            audit.write("started typing", device: s.device.info, agent: agent)
            control(agent, by: s, tookOverFrom: nil)
        } else {
            extend(agent)
        }
        return true
    }

    private func typed(_ s: Session, _ agent: UUID, _ bytes: [UInt8]) {
        guard host.agent(agent) != nil else { return }
        guard mayType(s, agent) else {
            if let c = controllers[agent] { s.send(.event(.inputRefused(agentId: agent, controller: c.device))) }
            return
        }
        host.session(agent)?.input(bytes)
    }

    private func control(_ agent: UUID, by s: Session, tookOverFrom: DeviceInfo?) {
        controllers[agent]?.release.cancel()
        let work = DispatchWorkItem { [weak self] in self?.release(agent) }
        controllers[agent] = Control(peer: s.peer.id, device: s.device.info, release: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + HostProtocol.controlTimeout, execute: work)
        broadcast(.controller(agentId: agent, controller: s.device.info, tookOverFrom: tookOverFrom))
        agentChanged(agent)
    }

    /// More typing: control lasts another 30 s.
    private func extend(_ agent: UUID) {
        guard var c = controllers[agent] else { return }
        c.release.cancel()
        let work = DispatchWorkItem { [weak self] in self?.release(agent) }
        c.release = work
        controllers[agent] = c
        DispatchQueue.main.asyncAfter(deadline: .now() + HostProtocol.controlTimeout, execute: work)
    }

    private func release(_ agent: UUID) {
        guard let c = controllers.removeValue(forKey: agent) else { return }
        c.release.cancel()
        broadcast(.controller(agentId: agent, controller: nil, tookOverFrom: nil))
        agentChanged(agent)
    }
}
