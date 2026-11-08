import Foundation
import HiveMindsCore
import HiveMindsProtocol

/// Agents and projects on hosts (HiveMinds Host), merged into the store's own lists so every screen shows them.
/// What a host says (`AgentInfo`) becomes an `Agent` and its `LiveState`; what you do to a remote agent goes to its
/// host as a request (docs/HOST-PROTOCOL.md §2.4). Nothing about a remote agent is saved on this Mac.
extension AppStore {
    // MARK: Looking up

    func remoteHost(of agentID: UUID) -> RemoteHost? { remoteAgentHost[agentID].flatMap { hosts.host($0) } }
    func remoteHost(ofProject projectID: UUID) -> RemoteHost? { remoteProjectHost[projectID].flatMap { hosts.host($0) } }
    func isRemote(_ agentID: UUID) -> Bool { remoteAgentHost[agentID] != nil }
    func isRemoteProject(_ projectID: UUID) -> Bool { remoteProjectHost[projectID] != nil }

    /// Whether a project is a git repository: asked of the folder here, or as its host said.
    func isGitRepo(_ projectID: UUID) -> Bool {
        if let host = remoteHost(ofProject: projectID) { return host.projects.first { $0.id == projectID }?.isGitRepo ?? false }
        return project(projectID)?.isGitRepo ?? false
    }

    /// What the host last said about one of its agents.
    func remoteInfo(_ agentID: UUID) -> AgentInfo? { remoteHost(of: agentID)?.agents[agentID] }

    /// Whether this Mac is the one typing in a remote agent.
    func isController(of agentID: UUID) -> Bool {
        guard let host = remoteHost(of: agentID), let c = host.agents[agentID]?.controller else { return false }
        return c.id == host.record.deviceID
    }

    /// Who else is typing in a remote agent, if anyone.
    func otherController(of agentID: UUID) -> DeviceInfo? {
        guard let host = remoteHost(of: agentID), let c = host.agents[agentID]?.controller, c.id != host.record.deviceID else { return nil }
        return c
    }

    /// Everyone watching a remote agent, this Mac included.
    func watchers(of agentID: UUID) -> [DeviceInfo] { remoteInfo(agentID)?.viewers ?? [] }

    // MARK: Asking hosts

    /// Sends a request whose answer is just "done"; a problem shows as a warning.
    func remote(_ host: RemoteHost, _ r: Request, _ verb: String) {
        Task {
            do {
                let reply = try await host.request(r)
                if let a = reply.agent { remoteAgentUpdated(a, on: host) }
            } catch {
                warning = "Couldn't \(verb) it on \(host.name): \(error.localizedDescription)"
            }
        }
    }

    func createRemoteAgent(on host: RemoteHost, projectID: UUID, provider: Provider, model: String, effort: Effort, access: Access,
                           planMode: Bool, role: String, task: String, ownBranch: Bool, open: Bool) async throws {
        let reply: Reply
        do {
            reply = try await host.request(.createAgent(CreateAgent(projectId: projectID, provider: provider.rawValue, model: model,
                                                                    effort: effort.rawValue, access: access.rawValue, planMode: planMode,
                                                                    role: role, task: task, ownBranch: ownBranch)))
        } catch {
            throw NewAgentError(error.localizedDescription)
        }
        guard let info = reply.agent else { throw NewAgentError("\(host.name) didn't say what it made.") }
        remoteAgentUpdated(info, on: host)
        if open { select(info.id) }
    }

    func removeRemoteAgent(_ agent: Agent, on host: RemoteHost) async -> Bool {
        do {
            let reply = try await host.request(.deleteAgent(AgentRef(agent.id)))
            picked.remove(agent.id)
            remoteAgentRemoved(agent.id)
            return !(reply.keptFolder ?? false)
        } catch {
            warning = "Couldn't delete \"\(agent.title)\" on \(host.name): \(error.localizedDescription)"
            return true
        }
    }

    func respondRemotely(_ id: UUID, _ action: PromptAction, on host: RemoteHost) {
        let answer: Answer = switch action {
        case .allow: Answer(id, action: "allow")
        case .decline: Answer(id, action: "decline")
        case .approvePlan: Answer(id, action: "approvePlan")
        case .keepPlanning(let feedback): Answer(id, action: "keepPlanning", feedback: feedback)
        case .answer(let answers): Answer(id, action: "answer", answers: answers.map {
            switch $0 {
            case .option(let n): .option(n)
            case .text(let t): .text(t)
            }
        })
        }
        Task {
            do {
                let reply = try await host.request(.answer(answer))
                var s = state(id)
                s.set(.working, reply.activity)
                live[id] = s
            } catch let e as HostRequestError where e.code == "notController" {
                // The host's message already says to take over.
                warning = e.errorDescription ?? "Someone else is typing in it. Take over to answer."
            } catch let e as HostRequestError where e.code == "notAsking" {
                notice = e.errorDescription
            } catch {
                warning = "Couldn't answer it on \(host.name): \(error.localizedDescription)"
            }
        }
    }

    /// Makes this Mac the one typing in a remote agent; the agent's terminal takes this Mac's size.
    func takeControl(_ id: UUID) {
        guard let host = remoteHost(of: id) else { return }
        Task {
            do {
                try await RemoteTerminals.shared.takeControl(id)
                remoteRefused[id] = nil
            } catch {
                warning = "Couldn't take over on \(host.name): \(error.localizedDescription)"
            }
        }
    }

    func remoteChanges(_ id: UUID, on host: RemoteHost) async throws -> ChangeSet {
        let r = try await host.request(.changes(AgentRef(id)))
        let files = (r.files ?? []).map { ChangedFile(path: $0.path, added: $0.added, removed: $0.removed, untracked: $0.untracked) }
        return ChangeSet(base: r.base ?? "", baseRef: r.baseRef ?? "HEAD", files: files, onlyItsOwn: r.onlyItsOwn ?? false)
    }

    func remoteDiff(_ id: UUID, file: ChangedFile, against set: ChangeSet, on host: RemoteHost) async -> (lines: [DiffLine], cut: Bool) {
        guard let r = try? await host.request(.diff(DiffRequest(id, path: file.path, baseRef: set.baseRef, untracked: file.untracked))) else {
            return ([], false)
        }
        let lines = (r.lines ?? []).enumerated().map { i, l in
            let kind: DiffLine.Kind = switch l.kind {
            case "added": .added
            case "removed": .removed
            case "hunk": .hunk
            case "meta": .meta
            default: .context
            }
            return DiffLine(id: i, kind: kind, text: l.text)
        }
        return (lines, r.cut ?? false)
    }

    /// The agents a host has deleted, newest first.
    func remoteHistory(_ host: RemoteHost) async -> [AgentInfo] {
        (try? await host.request(.history))?.agents ?? []
    }

    // MARK: What hosts say

    /// A host's projects and agents, all at once (on connecting, or when its projects change).
    func remoteSynced(_ host: RemoteHost) {
        let projectIDs = Set(host.projects.map(\.id))
        for p in host.projects {
            remoteProjectHost[p.id] = host.id
            if let i = projects.firstIndex(where: { $0.id == p.id }) {
                projects[i].name = p.name
                projects[i].repo = p.repo
            } else {
                projects.append(Project(id: p.id, name: p.name, path: "", repo: p.repo))
            }
        }
        for (id, hostID) in remoteProjectHost where hostID == host.id && !projectIDs.contains(id) {
            remoteProjectHost[id] = nil
            projects.removeAll { $0.id == id }
        }
        let agentIDs = Set(host.agents.keys)
        for (id, hostID) in remoteAgentHost where hostID == host.id && !agentIDs.contains(id) { remoteAgentRemoved(id) }
        for a in host.agents.values { remoteAgentUpdated(a, on: host) }
    }

    func remoteAgentUpdated(_ info: AgentInfo, on host: RemoteHost) {
        remoteAgentHost[info.id] = host.id
        var agent = agents.first { $0.id == info.id }
            ?? Agent(id: info.id, projectID: info.projectId, provider: Provider(rawValue: info.provider) ?? .claude,
                     model: info.model, role: "", cwd: "", hasStarted: true)
        agent.projectID = info.projectId
        agent.title = info.title
        agent.model = info.model
        agent.effort = info.effort.flatMap(Effort.init(rawValue:))
        agent.access = info.access.flatMap(Access.init(rawValue:))
        agent.branch = info.branch
        agent.createdAt = Date(timeIntervalSince1970: info.createdAt)
        if let i = agents.firstIndex(where: { $0.id == info.id }) {
            if agents[i] != agent { agents[i] = agent }
        } else {
            agents.append(agent)
        }

        let status = AgentStatus(rawValue: info.status) ?? .asleep
        let kind: PendingAsk.Kind? = switch info.ask {
        case .permission(let tool, let detail)?: .permission(tool: tool, detail: detail)
        case .questions(let q)?: .questions(q.map { AskQuestion(header: $0.header, question: $0.question, options: $0.options, multiSelect: $0.multiSelect) })
        case .plan(let p)?: .plan(p)
        case nil: nil
        }
        let old = state(info.id)
        if old.status != status || old.activity != info.activity {
            // The same sounds and badge as a local agent.
            let cue: Cue = if case .permission? = kind { .permission } else if info.activity.hasPrefix("Stopped on") { .error } else { .question }
            setStatus(info.id, status, info.activity, cue: cue)
        }
        var s = state(info.id)
        if s.ask?.kind != kind { s.ask = kind.map { PendingAsk(kind: $0) } }
        live[info.id] = s
        if remoteRefused[info.id] != nil, info.controller == nil || info.controller?.id == host.record.deviceID { remoteRefused[info.id] = nil }
    }

    func remoteAgentRemoved(_ id: UUID) {
        remoteAgentHost[id] = nil
        remoteRefused[id] = nil
        agents.removeAll { $0.id == id }
        live[id] = nil
        picked.remove(id)
        RemoteTerminals.shared.detached(id)
        if selection == .agent(id) { selection = .overview }
    }

    func remotePromptResolved(_ id: UUID, by: DeviceInfo, on host: RemoteHost) {
        guard by.id != host.record.deviceID else { return }
        var s = state(id)
        s.activity = "\(s.activity.isEmpty ? "Answered" : s.activity) by \(by.name)"
        live[id] = s
    }

    func remoteInputRefused(_ id: UUID, controller: DeviceInfo) {
        remoteRefused[id] = (controller, Date())
    }

    /// A host connected, dropped, was stopped or can't be used: its screens read `host.status`; this keeps the
    /// dock badge right.
    func remoteHostChanged(_ host: RemoteHost) {
        updateBadge()
    }

    func remoteHostForgotten(_ host: RemoteHost) {
        let ids = remoteAgentHost.filter { $0.value == host.id }.map(\.key)
        for id in ids { remoteAgentRemoved(id) }
        for (id, hostID) in remoteProjectHost where hostID == host.id {
            remoteProjectHost[id] = nil
            projects.removeAll { $0.id == id }
            if selection == .project(id) { selection = .overview }
        }
        RemoteTerminals.shared.drop(hostAgents: ids)
    }

    /// Projects on This Mac, and on each host, in the sidebar's order.
    var localShownProjects: [Project] { shownProjects.filter { remoteProjectHost[$0.id] == nil } }
    func shownProjects(on host: RemoteHost) -> [Project] { shownProjects.filter { remoteProjectHost[$0.id] == host.id } }
}
