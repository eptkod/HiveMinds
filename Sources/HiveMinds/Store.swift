import SwiftUI
import AppKit

@MainActor @Observable
final class AppStore {
    var projects: [Project] = []
    var agents: [Agent] = []
    var browserTabs: [BrowserTab] = []
    var shellTabs: [ShellTab] = []
    /// Each project's tile order on its Canvas, agents and browser tabs mixed.
    var canvasOrder: [UUID: [UUID]] = [:]
    /// Tiles you've sized by hand on each project's Canvas, by tile id. The rest fill the space left.
    var canvasPins: [UUID: [UUID: TilePin]] = [:]
    /// Tiles you've carried onto pages of their own on each project's Canvas: tile id to page group.
    var canvasGroups: [UUID: [UUID: Int]] = [:]
    var meetings: [Meeting] = []
    /// The meeting room that's open on the Meetings page, if any, and which of its tabs.
    var meetingSelection: UUID?
    var meetingTab: MeetingTab = .table
    var showingNewMeeting = false
    var newMeetingPattern: MeetingPattern?
    var pendingDeleteMeeting: Meeting?
    /// Text to type into an agent's terminal once its session is ready.
    var pendingInput: [UUID: String] = [:]
    var live: [UUID: LiveState] = [:] {
        didSet { KeepAwake.update(working: live.values.contains { $0.status == .working }) }
    }
    var mode: Mode = .agents
    var selection: SidebarItem? = .overview
    var showingNewAgent = false
    var newAgentProject: UUID?
    var pendingDelete: Agent?
    /// A project with agents still at work, waiting for you to confirm hiding it.
    var pendingHide: Project?
    var tools = Tools()
    var toolsChecked = false
    var errorMessage: String?
    var notice: String?
    /// Like `notice`, but for something to watch out for, such as an agent passing the cost warning.
    var warning: String?
    /// The agent whose Changes sheet is open.
    var showingChanges: Agent?
    /// A new access level or model, waiting for you to confirm the restart.
    var pendingRestart: PendingRestart?
    var showingPalette = false
    /// Bumped to rebuild an agent's terminal pane after a restart.
    var terminalGeneration: [UUID: Int] = [:]
    /// Agents you stopped. They stay stopped until you start them, rather than starting again when shown.
    var stopped: Set<UUID> = []
    let github = GitHubModel()
    let usage: UsageModel
    /// Tokens and estimated API cost per agent.
    let spend: SpendModel
    /// Agents you deleted, for the History page.
    let history: AgentHistoryModel

    let supportDir: URL
    let eventsDir: URL
    let statusDir: URL
    let hooksFile: URL
    /// The same settings plus `apiKeyHelper`, for agents that sign in with an API key.
    let hooksWithKeyFile: URL
    /// Only `apiKeyHelper`, for one-off Claude calls (chat titles, pull request text).
    let keyOnlyFile: URL
    let statusLineScript: URL
    private let stateFile: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var support = base.appendingPathComponent("HiveMinds", isDirectory: true)
        #if DEBUG
        // Lets test runs keep their state away from the real app's.
        if let dir = ProcessInfo.processInfo.environment["HIVEMINDS_SUPPORT_DIR"] { support = URL(fileURLWithPath: dir, isDirectory: true) }
        #endif
        supportDir = support
        eventsDir = supportDir.appendingPathComponent("events", isDirectory: true)
        statusDir = supportDir.appendingPathComponent("status", isDirectory: true)
        hooksFile = supportDir.appendingPathComponent("claude-hooks.json")
        hooksWithKeyFile = supportDir.appendingPathComponent("claude-hooks-api-key.json")
        keyOnlyFile = supportDir.appendingPathComponent("claude-api-key.json")
        stateFile = supportDir.appendingPathComponent("state.json")
        statusLineScript = supportDir.appendingPathComponent("statusline.sh")
        usage = UsageModel(file: supportDir.appendingPathComponent("usage.json"))
        let statusDir = statusDir
        spend = SpendModel(file: supportDir.appendingPathComponent("spend.json")) {
            statusDir.appendingPathComponent("\($0.uuidString).json")
        }
        history = AgentHistoryModel(file: supportDir.appendingPathComponent("agent-history.json"))
        for dir in [supportDir, eventsDir, statusDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        writeHooksFile()
        load()
        for a in agents where a.provider == .claude {
            if isHidden(a) { spend.park(a.id) } else { spend.watch(a.id) }
        }
        spend.onCostChange = { [weak self] id, old, new in self?.checkCost(id, old, new) }
        Terminals.shared.store = self
    }

    func bootstrap() async {
        tools = await Task.detached { Tools.detect() }.value
        toolsChecked = true
        github.gh = tools.gh
        await github.refresh()
    }

    func recheckTools() async {
        toolsChecked = false
        await bootstrap()
    }

    // MARK: Persistence

    private struct Saved: Codable {
        var projects: [Project]
        var agents: [Agent]
        var browserTabs: [BrowserTab]?
        var shellTabs: [ShellTab]?
        var canvasOrder: [UUID: [UUID]]?
        var canvasPins: [UUID: [UUID: TilePin]]?
        var canvasGroups: [UUID: [UUID: Int]]?
        var meetings: [Meeting]?
    }

    private func load() {
        guard let data = try? Data(contentsOf: stateFile),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        projects = saved.projects
        agents = saved.agents
        browserTabs = saved.browserTabs ?? []
        shellTabs = saved.shellTabs ?? []
        canvasOrder = saved.canvasOrder ?? [:]
        canvasPins = saved.canvasPins ?? [:]
        canvasGroups = saved.canvasGroups ?? [:]
        meetings = saved.meetings ?? []
        // Meetings that were running when the app quit wait for you to resume them.
        for i in meetings.indices where meetings[i].status == .running {
            meetings[i].status = .paused
            meetings[i].note = "Paused when HiveMinds closed. Resume to carry on."
        }
        // Agents used to get made-up names. Those become untitled and pick up a title from their next request.
        let oldNames: Set = ["Atlas", "Nova", "Echo", "Juniper", "Orion", "Sage", "Quill", "Rook", "Wren", "Vega",
                             "Lumen", "Cobalt", "Ember", "Fern", "Indigo", "Kestrel", "Lyra", "Moss", "Onyx", "Pike"]
        for i in agents.indices where oldNames.contains(agents[i].title) || agents[i].title.hasPrefix("Agent ") {
            agents[i].title = Agent.untitled
        }
        for a in agents { live[a.id] = LiveState() }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(Saved(projects: projects, agents: agents, browserTabs: browserTabs, shellTabs: shellTabs, canvasOrder: canvasOrder, canvasPins: canvasPins, canvasGroups: canvasGroups, meetings: meetings)) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    /// Claude Code hooks that append each event, one JSON object per line, to the file the agent was
    /// started with. The app watches those files: no server, nothing listening on a port.
    private func writeHooksFile() {
        let command = #"[ -n "$HIVEMINDS_EVENTS" ] && { tr -d '\n' >> "$HIVEMINDS_EVENTS"; echo >> "$HIVEMINDS_EVENTS"; }; true"#
        let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "Notification", "PermissionRequest", "StopFailure", "SessionEnd"]
        var hooks: [String: Any] = [:]
        for e in events { hooks[e] = [["hooks": [["type": "command", "command": command]]]] }
        writeStatusLineScript()
        let settings: [String: Any] = [
            "hooks": hooks,
            "statusLine": ["type": "command", "command": "/bin/sh '\(statusLineScript.path)'"],
        ]
        // Claude Code asks this command for the key. It prints our variable, so the key itself never touches disk.
        let keyHelper = ["apiKeyHelper": "printenv \(SignIn.envName(for: .claude))"]
        for (file, contents) in [(hooksFile, settings), (hooksWithKeyFile, settings.merging(keyHelper) { $1 }),
                                 (keyOnlyFile, keyHelper)] {
            if let data = try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// Settings for a one-off Claude call, so it uses the API key when Claude signs in with one.
    var claudeKeyArgs: [String] {
        SignIn.apiKey(for: .claude) != nil ? ["--settings", keyOnlyFile.path] : []
    }

    /// Claude Code hands its status line command the session's state, including how much of the plan's
    /// 5-hour and weekly limits is used. The script saves that for the usage meter, then runs your own
    /// status line from ~/.claude/settings.json, if you have one, so agents look as they would elsewhere.
    private func writeStatusLineScript() {
        let usageFile = usage.file.path
        var script = """
        #!/bin/sh
        # Written by HiveMinds on every launch.
        input=$(cat)
        case "$input" in *'"rate_limits"'*) printf '%s' "$input" > '\(usageFile)' ;; esac
        [ -n "$HIVEMINDS_STATUS" ] && printf '%s' "$input" > "$HIVEMINDS_STATUS"

        """
        let userSettings = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: userSettings),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let line = json["statusLine"] as? [String: Any], let own = line["command"] as? String, !own.isEmpty {
            script += "printf '%s' \"$input\" | \(own)\n"
        }
        try? script.write(to: statusLineScript, atomically: true, encoding: .utf8)
    }

    func eventsFile(for id: UUID) -> URL { eventsDir.appendingPathComponent("\(id.uuidString).jsonl") }
    /// The latest status line input of an agent's session, which carries its cost and token counts.
    func statusFile(for id: UUID) -> URL { statusDir.appendingPathComponent("\(id.uuidString).json") }

    // MARK: Lookup

    func agent(_ id: UUID) -> Agent? { agents.first { $0.id == id } }
    func project(_ id: UUID) -> Project? { projects.first { $0.id == id } }
    /// A project's own agents. Agents sitting in a meeting belong to the meeting room instead.
    func agents(in project: Project) -> [Agent] { agents.filter { $0.projectID == project.id && $0.meetingID == nil } }
    var workspaceAgents: [Agent] { agents.filter { $0.meetingID == nil && !isHidden($0) } }
    func state(_ id: UUID) -> LiveState { live[id] ?? LiveState() }

    /// Projects in the sidebar, and the ones tucked away in Settings > Projects.
    var shownProjects: [Project] { projects.filter { !$0.isHidden } }
    var hiddenProjects: [Project] { projects.filter(\.isHidden) }
    func isHidden(_ agent: Agent) -> Bool { project(agent.projectID)?.isHidden == true }
    var shownMeetings: [Meeting] { meetings.filter { project($0.projectID)?.isHidden != true } }

    var waitingAgents: [Agent] { agents.filter { state($0.id).status == .needsYou && !isHidden($0) } }

    func select(_ id: UUID) {
        // Opening an agent from History or the palette brings its project back.
        if let a = agent(id), let p = project(a.projectID), p.isHidden { showProject(p) }
        if let meetingID = agent(id)?.meetingID {
            openMeeting(meetingID, tab: .seat(id))
            return
        }
        mode = .agents
        selection = .agent(id)
    }

    func jumpToWaiting() {
        if let a = waitingAgents.first { select(a.id) }
    }

    // MARK: Projects

    @discardableResult
    func addProject(path: String, repo: String?) -> Project {
        let clean = (path as NSString).standardizingPath
        if let existing = projects.first(where: { $0.path == clean }) { return existing }
        let name = repo.map { String($0.split(separator: "/").last ?? Substring($0)) } ?? (clean as NSString).lastPathComponent
        let p = Project(name: name, path: clean, repo: repo)
        projects.append(p)
        save()
        return p
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        panel.message = "Pick the folder your agents should work in."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let p = addProject(path: url.path, repo: nil)
        Task { await detectRepo(p) }
    }

    private func detectRepo(_ p: Project) async {
        guard let gh = tools.gh, p.isGitRepo else { return }
        let r = await Shell.run(gh, ["repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"], cwd: p.path)
        let repo = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.ok, !repo.isEmpty, let i = projects.firstIndex(where: { $0.id == p.id }) {
            projects[i].repo = repo
            save()
        }
    }

    /// An existing checkout of a GitHub repo: in the projects folder, an Agent Office checkout, or where older builds cloned it.
    private func existingCheckout(for repo: String) async -> String? {
        let home = NSHomeDirectory()
        var candidates = ["\(home)/agent-office/projects/\(repo)", "\(home)/HiveMinds/projects/\(repo)"]
        if let folder = ProjectFolder.path {
            candidates.insert(contentsOf: ProjectFolder.destinations(for: repo, in: folder), at: 0)
        }
        for path in candidates where await isCheckout(path, of: repo) { return path }
        return nil
    }

    /// Whether `path` is a git checkout whose origin is `repo`.
    private func isCheckout(_ path: String, of repo: String) async -> Bool {
        guard FileManager.default.fileExists(atPath: path + "/.git"), let git = tools.git else { return false }
        let r = await Shell.run(git, ["remote", "get-url", "origin"], cwd: path)
        var url = r.out.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if url.hasSuffix(".git") { url.removeLast(4) }
        return r.ok && (url.hasSuffix("/" + repo.lowercased()) || url.hasSuffix(":" + repo.lowercased()))
    }

    func hasProject(repo: String) -> Bool { projects.contains { $0.repo == repo } }

    func addRepo(_ repo: String) async {
        guard let gh = tools.gh else { return }
        var dest = await existingCheckout(for: repo)
        if dest == nil {
            // The first download asks where projects go; later ones use that folder.
            guard let folder = ProjectFolder.path ?? ProjectFolder.choose(firstTime: true) else { return }
            dest = ProjectFolder.destinations(for: repo, in: folder).first { !FileManager.default.fileExists(atPath: $0) }
            guard let target = dest else {
                errorMessage = "Couldn't download \(repo): \(folder) already has folders with its name."
                return
            }
            github.cloning.insert(repo)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let r = await Shell.run(gh, ["repo", "clone", repo, target])
            github.cloning.remove(repo)
            guard r.ok else {
                errorMessage = "Couldn't download \(repo). \(r.message)"
                return
            }
        }
        guard let dest else { return }
        addProject(path: dest, repo: repo)
        notice = "\(repo) added. Its files are in \(dest)."
    }

    func removeProject(_ project: Project) {
        let gone = agents.filter { $0.projectID == project.id }
        remember(gone)
        for a in gone {
            Terminals.shared.stop(a.id)
            spend.forget(a.id, from: project)
            live.removeValue(forKey: a.id)
            try? FileManager.default.removeItem(at: eventsFile(for: a.id))
            try? FileManager.default.removeItem(at: statusFile(for: a.id))
        }
        agents.removeAll { $0.projectID == project.id }
        meetings.removeAll { $0.projectID == project.id }
        if let id = meetingSelection, meeting(id) == nil { meetingSelection = nil }
        for t in browserTabs(in: project) { Browsers.close(t.id) }
        browserTabs.removeAll { $0.projectID == project.id }
        for t in shellTabs(in: project) { Shells.shared.close(t.id) }
        shellTabs.removeAll { $0.projectID == project.id }
        canvasOrder.removeValue(forKey: project.id)
        canvasPins.removeValue(forKey: project.id)
        canvasGroups.removeValue(forKey: project.id)
        projects.removeAll { $0.id == project.id }
        selection = .overview
        save()
    }

    /// Hides a project, or asks first if any of its agents or meetings are still at work, since hiding stops them.
    func requestHide(_ project: Project) {
        let ids = agents.filter { $0.projectID == project.id }.map(\.id)
        let busy = ids.contains { [.working, .starting].contains(state($0).status) }
            || meetings.contains { $0.projectID == project.id && $0.status == .running }
        if busy { pendingHide = project } else { hideProject(project) }
    }

    /// Takes a project out of the sidebar and lets go of everything it was using: its agents' processes,
    /// file watches and event logs, and its browser and shell tabs. What's kept is the agents' settings and
    /// chats (Claude Code saves those itself), so each picks up where it left off when the project is shown.
    func hideProject(_ project: Project) {
        pendingHide = nil
        // Leave its workspace first, so no terminal on screen starts its agent again.
        if currentProjectID == project.id { selection = .overview }
        if let id = meetingSelection, meeting(id)?.projectID == project.id { meetingSelection = nil }
        for m in meetings where m.projectID == project.id && m.status == .running { pauseMeeting(m.id) }
        for a in agents where a.projectID == project.id {
            Terminals.shared.stop(a.id)
            pendingInput[a.id] = nil
            if a.provider == .claude { spend.park(a.id) }
            live[a.id] = LiveState()
            // Started empty every time the agent starts, so nothing is lost.
            try? FileManager.default.removeItem(at: eventsFile(for: a.id))
        }
        for t in browserTabs(in: project) { Browsers.close(t.id) }
        for t in shellTabs(in: project) { Shells.shared.close(t.id) }
        setHidden(project.id, true)
        notice = "\(project.name) is hidden. Show it again from Settings > Projects."
    }

    /// Puts a hidden project back in the sidebar. Its agents start when you open them, as after a relaunch.
    func showProject(_ project: Project) {
        for a in agents where a.projectID == project.id && a.provider == .claude { spend.watch(a.id) }
        setHidden(project.id, false)
    }

    private func setHidden(_ id: UUID, _ hidden: Bool) {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[i].hidden = hidden ? true : nil
        save()
        updateBadge()
    }

    /// Moves a project into another's place in the sidebar, so dragging up lands it above that project
    /// and dragging down lands it below.
    func moveProject(_ id: UUID, to targetID: UUID) {
        guard id != targetID,
              let from = projects.firstIndex(where: { $0.id == id }),
              let to = projects.firstIndex(where: { $0.id == targetID }) else { return }
        projects.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        save()
    }

    // MARK: Agents

    /// Opens the New Agent sheet. With a project (or one to infer from what's selected) the sheet doesn't ask for one.
    func beginNewAgent(in projectID: UUID?) {
        newAgentProject = projectID ?? currentProjectID ?? (shownProjects.count == 1 ? shownProjects.first?.id : nil)
        showingNewAgent = true
    }

    /// The project whose workspace is showing, if any.
    var currentProjectID: UUID? {
        switch selection {
        case .agent(let id): agent(id)?.projectID
        case .project(let id): project(id)?.id
        case .browser(let id): browserTab(id)?.projectID
        case .shell(let id): shellTab(id)?.projectID
        case .meeting(let id): meeting(id)?.projectID
        case .overview, .history, nil: nil
        }
    }

    struct NewAgentError: LocalizedError {
        var errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    func createAgent(projectID: UUID, provider: Provider, model: String, effort: Effort = AgentDefaults.effort,
                     access: Access = AgentDefaults.access, role: String, task: String, attachments: [Attachment] = [], ownBranch: Bool,
                     issue: IssueRef? = nil, open: Bool = true) async throws {
        guard let project = project(projectID) else { throw NewAgentError("Pick a project first.") }
        let t = task.trimmingCharacters(in: .whitespacesAndNewlines)
        var cwd = project.path
        var branch: String?
        if ownBranch {
            let suffix = String(UUID().uuidString.prefix(4)).lowercased()
            let name = issue.map { "issue-\($0.number)-\($0.title)" } ?? (t.isEmpty ? "agent" : Agent.roughTitle(t))
            (cwd, branch) = try await makeWorktree(project: project, slug: "\(slugify(name))-\(suffix)")
        }
        // Attachments are copied into the agent's own folder, where it can read them without asking,
        // and kept out of git like the rest of `.hiveminds`.
        var paths: [String] = []
        if !attachments.isEmpty {
            excludeFromGit(project: project, pattern: "/.hiveminds/")
            let folder = URL(filePath: cwd).appending(path: ".hiveminds/attachments/\(UUID().uuidString.prefix(8).lowercased())")
            do { paths = try Attachment.save(attachments, to: folder) }
            catch { throw NewAgentError("Couldn't copy the attachments. \(error.localizedDescription)") }
        }
        let prompt = Attachment.prompt(t, paths: paths)
        var agent = Agent(projectID: projectID, provider: provider, model: model, effort: effort, access: access,
                          role: role.trimmingCharacters(in: .whitespacesAndNewlines),
                          cwd: cwd, branch: branch, pendingTask: prompt.isEmpty ? nil : prompt)
        agent.issue = issue
        // An issue already has a title someone wrote, so it doesn't need one from Haiku.
        if let issue { agent.title = Agent.roughTitle(issue.title) } else if !t.isEmpty { agent.title = Agent.roughTitle(t) }
        agents.append(agent)
        live[agent.id] = LiveState(status: .starting, activity: "Starting up")
        save()
        // Not opened: start it in the background, the way meeting seats run.
        if open { select(agent.id) } else { _ = Terminals.shared.view(for: agent) }
        if issue == nil && !t.isEmpty { nameChat(agent.id, from: t) }
    }

    /// Asks Haiku for a short title for the chat, in the background. The rough title stays if that fails.
    private func nameChat(_ id: UUID, from prompt: String) {
        guard AgentDefaults.autoTitles, let claude = tools.claude else { return }
        let ask = "Write a short title (3 to 6 words, no quotes, no trailing period) for a coding chat that starts "
            + "with this request. Reply with only the title.\n\nRequest: \(prompt.prefix(2000))"
        Task {
            // The prompt goes before the flags: --tools takes every word after it.
            let r = await Shell.run(claude, ["-p", ask, "--model", "haiku", "--no-session-persistence"] + claudeKeyArgs + ["--tools", ""],
                                    cwd: supportDir.path, env: SignIn.environment(for: .claude))
            let title = r.out.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'.")))
            guard r.ok, !title.isEmpty, title.count <= 80, !title.contains("\n") else { return }
            update(id) { $0.title = title }
        }
    }

    /// A new git worktree on its own branch, `hive/<slug>`, inside the project.
    func makeWorktree(project: Project, slug: String) async throws -> (String, String) {
        guard let git = tools.git else { throw NewAgentError("git isn't installed, so the agent can't get its own branch.") }
        guard project.isGitRepo else { throw NewAgentError("\(project.name) isn't a git repository, so the agent can't get its own branch. Turn off \"Own branch\".") }
        let branch = "hive/\(slug)"
        // Inside the project, like Agent Office: trusting the project in Claude Code then covers every
        // agent's folder, so new agents don't stop at Claude Code's "trust this folder?" question.
        let path = "\(project.path)/.hiveminds/worktrees/\(slug)"
        excludeFromGit(project: project, pattern: "/.hiveminds/")
        let r = await Shell.run(git, ["-C", project.path, "worktree", "add", "-b", branch, path])
        guard r.ok else {
            let hint = r.message.contains("invalid reference") || r.message.contains("not a valid object")
                ? " The repository has no commits yet. Make a first commit, or turn off \"Own branch\"." : ""
            throw NewAgentError("Couldn't make a branch for the agent. \(r.message)\(hint)")
        }
        return (path, branch)
    }

    /// Keeps the agents' folders out of `git status` without changing any file in the repository.
    private func excludeFromGit(project: Project, pattern: String) {
        let file = "\(project.path)/.git/info/exclude"
        let current = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(Substring(pattern)) else { return }
        try? FileManager.default.createDirectory(atPath: "\(project.path)/.git/info", withIntermediateDirectories: true)
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + pattern + "\n"
        try? (current + line).write(toFile: file, atomically: true, encoding: .utf8)
    }

    func update(_ id: UUID, _ change: (inout Agent) -> Void) {
        guard let i = agents.firstIndex(where: { $0.id == id }) else { return }
        change(&agents[i])
        save()
    }

    /// Starts an agent that isn't running. Its terminal starts the CLI once it's on screen.
    func start(_ id: UUID) {
        stopped.remove(id)
        live[id] = LiveState(status: .starting, activity: "Starting up")
        terminalGeneration[id, default: 0] += 1
    }

    func restart(_ id: UUID) {
        stopped.remove(id)
        Terminals.shared.stop(id)
        live[id] = LiveState(status: .starting, activity: "Starting up")
        terminalGeneration[id, default: 0] += 1
    }

    func stop(_ id: UUID) {
        Terminals.shared.stop(id)
        stopped.insert(id)
        setStatus(id, .asleep, "Stopped")
        terminalGeneration[id, default: 0] += 1
    }

    /// Removes the agent. Its worktree goes too, but only if it has no uncommitted changes; its branch,
    /// and so any commits on it, always stays.
    func deleteAgent(_ agent: Agent) async {
        Terminals.shared.stop(agent.id)
        if agent.branch != nil, let git = tools.git, let project = project(agent.projectID) {
            let r = await Shell.run(git, ["-C", project.path, "worktree", "remove", agent.cwd])
            if !r.ok {
                notice = "The folder for \"\(agent.title)\" was kept because it has changes that aren't committed: \(agent.cwd)"
            }
        }
        remember([agent])
        agents.removeAll { $0.id == agent.id }
        live.removeValue(forKey: agent.id)
        spend.forget(agent.id, from: project(agent.projectID))
        try? FileManager.default.removeItem(at: eventsFile(for: agent.id))
        try? FileManager.default.removeItem(at: statusFile(for: agent.id))
        if selection == .agent(agent.id) { selection = .project(agent.projectID) }
        save()
        updateBadge()
    }

    /// Puts a project's agents in the given order. Agents in other projects keep their places.
    func reorderAgents(in projectID: UUID, _ order: [UUID]) {
        let slots = agents.indices.filter { agents[$0].projectID == projectID && agents[$0].meetingID == nil }
        let mine = order.compactMap { id in agents.first { $0.id == id && $0.projectID == projectID && $0.meetingID == nil } }
        guard mine.count == slots.count else { return }
        for (slot, agent) in zip(slots, mine) { agents[slot] = agent }
        save()
    }

    /// What a project's Canvas shows, in order: its agents, browser tabs, shells and meetings, by id.
    /// Anything the saved order doesn't know yet goes at the end.
    func canvasItems(in project: Project) -> [UUID] {
        let current = agents(in: project).map(\.id) + browserTabs(in: project).map(\.id) + shellTabs(in: project).map(\.id) + canvasMeetings(in: project).map(\.id)
        let saved = canvasOrder[project.id, default: []].filter(current.contains)
        return saved + current.filter { !saved.contains($0) }
    }

    /// Saves a new Canvas order, and puts the sidebar and tab row in the same order.
    func reorderCanvas(in projectID: UUID, _ order: [UUID]) {
        canvasOrder[projectID] = order
        reorderAgents(in: projectID, order.filter { id in agents.contains { $0.id == id } })
        let slots = browserTabs.indices.filter { browserTabs[$0].projectID == projectID }
        let mine = order.compactMap { id in browserTabs.first { $0.id == id && $0.projectID == projectID } }
        if mine.count == slots.count {
            for (slot, tab) in zip(slots, mine) { browserTabs[slot] = tab }
        }
        let shellSlots = shellTabs.indices.filter { shellTabs[$0].projectID == projectID }
        let myShells = order.compactMap { id in shellTabs.first { $0.id == id && $0.projectID == projectID } }
        if myShells.count == shellSlots.count {
            for (slot, tab) in zip(shellSlots, myShells) { shellTabs[slot] = tab }
        }
        save()
    }

    /// Saves which Canvas tiles have a size you picked. Ones that are gone are dropped.
    func pinCanvas(in project: Project, _ pins: [UUID: TilePin]) {
        let current = Set(canvasItems(in: project))
        canvasPins[project.id] = pins.filter { current.contains($0.key) }
        save()
    }

    /// Saves which Canvas tiles you've carried onto pages of their own. Ones that are gone are dropped.
    func groupCanvas(in project: Project, _ groups: [UUID: Int]) {
        let current = Set(canvasItems(in: project))
        canvasGroups[project.id] = groups.filter { current.contains($0.key) }
        save()
    }

    // MARK: Browser tabs

    func browserTab(_ id: UUID) -> BrowserTab? { browserTabs.first { $0.id == id } }
    func browserTabs(in project: Project) -> [BrowserTab] { browserTabs.filter { $0.projectID == project.id } }

    func newBrowserTab(in projectID: UUID, url: String = "") {
        let tab = BrowserTab(projectID: projectID, url: url)
        browserTabs.append(tab)
        save()
        mode = .agents
        selection = .browser(tab.id)
    }

    func closeBrowserTab(_ id: UUID) {
        guard let tab = browserTab(id) else { return }
        Browsers.close(id)
        browserTabs.removeAll { $0.id == id }
        if selection == .browser(id) { selection = .project(tab.projectID) }
        save()
    }

    // MARK: Shell tabs

    func shellTab(_ id: UUID) -> ShellTab? { shellTabs.first { $0.id == id } }
    func shellTabs(in project: Project) -> [ShellTab] { shellTabs.filter { $0.projectID == project.id } }

    func newShellTab(in projectID: UUID) {
        let tab = ShellTab(projectID: projectID)
        shellTabs.append(tab)
        save()
        mode = .agents
        selection = .shell(tab.id)
    }

    func closeShellTab(_ id: UUID) {
        guard let tab = shellTab(id) else { return }
        Shells.shared.close(id)
        shellTabs.removeAll { $0.id == id }
        if selection == .shell(id) { selection = .project(tab.projectID) }
        save()
    }

    /// ⌘W: closes the open tab instead of the window. A browser or shell tab closes; an agent tab steps back to
    /// the Canvas (the agent keeps running); a meeting seat or outcome steps back to the table, and the
    /// table back to the meeting list. Anywhere else it does nothing, so ⌘W never quits the app.
    func closeCurrentTab() {
        switch mode {
        case .agents:
            switch selection {
            case .browser(let id): closeBrowserTab(id)
            case .shell(let id): closeShellTab(id)
            case .agent(let id): if let agent = agent(id) { selection = .project(agent.projectID) }
            case .meeting(let id): if let m = meeting(id) { selection = .project(m.projectID) }
            default: break
            }
        case .meetings:
            guard meetingSelection != nil else { return }
            if meetingTab == .table { meetingSelection = nil } else { meetingTab = .table }
        default: break
        }
    }

    /// Remembers where a tab is, so it reopens there after a relaunch.
    func browserTabChanged(_ id: UUID, url: String, title: String) {
        guard let i = browserTabs.firstIndex(where: { $0.id == id }),
              browserTabs[i].url != url || browserTabs[i].title != title else { return }
        browserTabs[i].url = url
        browserTabs[i].title = title
        save()
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    /// Opens the file's folder in Finder with the file selected.
    func revealFile(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Status

    /// `cue` is the sound for an agent that starts needing you; it says why (permission, a question, an error).
    func setStatus(_ id: UUID, _ status: AgentStatus, _ activity: String? = nil, cue: Cue = .question) {
        let old = state(id).status
        var s = state(id)
        s.status = status
        if status != .needsYou { s.ask = nil }
        if let activity { s.activity = activity }
        s.updated = Date()
        live[id] = s
        if status == .needsYou && old != .needsYou {
            Sounds.play(cue)
            NSApp.requestUserAttention(.informationalRequest)
        } else if status == .done && old == .working && agent(id)?.meetingID == nil {
            Sounds.play(.done)
        }
        updateBadge()
    }

    /// Warns once when an agent's estimated cost passes the amount in Settings > Agents. It never pauses the agent.
    private func checkCost(_ id: UUID, _ old: Double, _ new: Double) {
        let limit = AgentDefaults.costWarning
        guard limit > 0, old < limit, new >= limit, let agent = agent(id) else { return }
        warning = "\"\(agent.title)\" has used about \(TokenBadge.money(new)) at API prices (an estimate), past your \(TokenBadge.money(limit)) warning."
    }

    private func updateBadge() {
        let n = waitingAgents.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    /// One Claude Code hook event, as the hook wrote it.
    func apply(event: [String: Any], to id: UUID) {
        guard agent(id) != nil, let name = event["hook_event_name"] as? String else { return }
        switch name {
        case "SessionStart":
            if state(id).status == .starting || state(id).status == .asleep { setStatus(id, .idle, "Ready for a task") }
            if let text = pendingInput.removeValue(forKey: id) {
                // Give Claude Code a moment to draw its prompt before typing into it.
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    Terminals.shared.type(id, text)
                }
            }
        case "UserPromptSubmit":
            if agent(id)?.hasStarted == false { update(id) { $0.hasStarted = true; $0.pendingTask = nil } }
            let prompt = (event["prompt"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            if agent(id)?.isUntitled == true, !prompt.trimmingCharacters(in: .whitespaces).isEmpty, !prompt.hasPrefix("/") {
                update(id) { $0.title = Agent.roughTitle(prompt) }
                nameChat(id, from: prompt)
            }
            setStatus(id, .working, prompt.isEmpty ? "Thinking" : "Asked: \(prompt.prefix(120))")
        case "PreToolUse":
            if event["tool_name"] as? String == "AskUserQuestion" {
                setStatus(id, .needsYou, "Has a question for you", cue: .question)
                setAsk(id, .questions(AskQuestion.parse(event["tool_input"] as? [String: Any] ?? [:])))
            } else {
                setStatus(id, .working, describeTool(event))
            }
        case "PermissionRequest":
            let tool = event["tool_name"] as? String ?? "a tool"
            let input = event["tool_input"] as? [String: Any] ?? [:]
            if tool == "AskUserQuestion" {
                setStatus(id, .needsYou, "Has a question for you", cue: .question)
                setAsk(id, .questions(AskQuestion.parse(input)))
            } else {
                setStatus(id, .needsYou, "Wants permission to use \(tool)", cue: .permission)
                setAsk(id, .permission(tool: tool, detail: permissionDetail(tool, input)))
            }
        case "Notification":
            let type = event["notification_type"] as? String ?? ""
            let message = event["message"] as? String ?? "Waiting for you"
            if type == "idle_prompt" {
                if state(id).status == .working { setStatus(id, .needsYou, message) }
            } else if state(id).activity != "Has a question for you" {
                setStatus(id, .needsYou, message, cue: type == "permission_prompt" ? .permission : .question)
            }
        case "StopFailure":
            // The turn ended on an error (an API error, a rate limit, a lost connection) rather than finishing.
            let error = (event["error"] as? String).map { $0.replacingOccurrences(of: "_", with: " ") } ?? "an error"
            setStatus(id, .needsYou, "Stopped on \(error)", cue: .error)
        case "Stop":
            setStatus(id, .done, state(id).activity.hasPrefix("Asked:") ? "Finished" : "Finished · \(state(id).activity)")
            meetingTurnEnded(id)
            // Notices a pull request the agent opened itself.
            if agent(id)?.branch != nil { Task { await refreshPullRequest(id) } }
        case "SessionEnd":
            setStatus(id, .asleep, "Session ended")
        default:
            break
        }
    }

    private func setAsk(_ id: UUID, _ kind: PendingAsk.Kind) {
        if case .questions(let q) = kind, q.isEmpty { return }
        live[id, default: LiveState()].ask = PendingAsk(kind: kind)
    }

    /// What a permission prompt is about, as you'd want to check it: the command itself, or the file.
    private func permissionDetail(_ tool: String, _ input: [String: Any]) -> String {
        switch tool {
        case "Bash": (input["command"] as? String) ?? describeToolUse(tool, input)
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            (input["file_path"] as? String ?? input["notebook_path"] as? String) ?? describeToolUse(tool, input)
        case "WebFetch": (input["url"] as? String) ?? describeToolUse(tool, input)
        default: describeToolUse(tool, input)
        }
    }

    // MARK: Answering from a tile
    // These press the same keys you would in the agent's terminal, so the terminal stays the one source of truth.

    /// Says yes once to a permission prompt (its first option).
    func allow(_ id: UUID) {
        guard state(id).ask != nil else { return }
        Terminals.shared.press(id, ["1"])
        setStatus(id, .working, "Allowed")
    }

    /// Says no to a permission prompt or skips a question. Claude Code then waits for you to say what to do instead.
    func decline(_ id: UUID) {
        guard state(id).ask != nil else { return }
        Terminals.shared.press(id, ["\u{1b}"])
        setStatus(id, .idle, "You said no. Tell it what to do instead.")
    }

    /// Answers every question in an AskUserQuestion prompt: an option's index, or your own words.
    func answer(_ id: UUID, _ answers: [QuestionAnswer]) {
        guard case .questions(let questions)? = state(id).ask?.kind, answers.count == questions.count else { return }
        var keys: [String] = []
        for (q, a) in zip(questions, answers) {
            switch a {
            case .option(let i): keys.append("\(i + 1)")
            case .text(let text):
                // The option after the listed ones is "Type something".
                keys.append("\(q.options.count + 1)")
                keys.append(text.replacingOccurrences(of: "\n", with: " "))
                keys.append("\r")
            }
        }
        // With more than one question, Claude Code shows your answers and asks you to submit them.
        if questions.count > 1 { keys.append("1") }
        Terminals.shared.press(id, keys)
        setStatus(id, .working, "Answered")
    }

    private func describeTool(_ e: [String: Any]) -> String {
        describeToolUse(e["tool_name"] as? String ?? "a tool", e["tool_input"] as? [String: Any] ?? [:])
    }
}

/// What a tool call is doing, in plain words: "Editing App.swift", "Running the tests".
nonisolated func describeToolUse(_ tool: String, _ input: [String: Any]) -> String {
    func file(_ k: String) -> String { ((input[k] as? String) ?? "").split(separator: "/").last.map(String.init) ?? "" }
    switch tool {
    case "Bash": return "Running \((input["description"] as? String) ?? (input["command"] as? String ?? "a command"))"
    case "Read": return "Reading \(file("file_path"))"
    case "Edit", "MultiEdit": return "Editing \(file("file_path"))"
    case "Write": return "Writing \(file("file_path"))"
    case "Grep", "Glob": return "Searching the code"
    case "WebFetch", "WebSearch": return "Looking something up online"
    case "Task", "Agent": return "Handing part of the work to a helper"
    case "TodoWrite": return "Planning the steps"
    default: return "Using \(tool)"
    }
}
