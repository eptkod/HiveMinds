import Foundation

/// What someone asked for in New Agent.
package struct NewAgent: Sendable {
    package var provider: Provider
    package var model: String
    package var effort: Effort
    package var access: Access
    package var planMode: Bool
    package var role: String
    /// The first request, as typed.
    package var task: String
    package var ownBranch: Bool
    package var issue: IssueRef?
    /// A title someone already wrote (a split's planner names each task), used instead of one from the request.
    package var title: String?

    package init(provider: Provider, model: String, effort: Effort, access: Access, planMode: Bool = false, role: String = "",
                 task: String, ownBranch: Bool, issue: IssueRef? = nil, title: String? = nil) {
        self.provider = provider
        self.model = model
        self.effort = effort
        self.access = access
        self.planMode = planMode
        self.role = role
        self.task = task
        self.ownBranch = ownBranch
        self.issue = issue
        self.title = title
    }

    /// The request with surrounding blank space removed.
    package var trimmedTask: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Turning a New Agent request into an agent: its branch name, its first prompt and its title.
package enum AgentFactory {
    /// The name for its own branch and folder (`hive/<slug>`): from the issue, the given title or the request,
    /// plus four random characters so two agents on the same thing don't clash.
    package static func branchSlug(_ r: NewAgent, suffix: String = String(UUID().uuidString.prefix(4)).lowercased()) -> String {
        let t = r.trimmedTask
        let name = r.issue.map { "issue-\($0.number)-\($0.title)" } ?? r.title ?? (t.isEmpty ? "agent" : Agent.roughTitle(t))
        return "\(slugify(name))-\(suffix)"
    }

    /// The agent, working in `cwd` (on `branch` when it has its own). `prompt` is the first message to send, which
    /// may add attachment paths to the request.
    package static func make(_ r: NewAgent, projectID: UUID, cwd: String, branch: String?, prompt: String) -> Agent {
        let t = r.trimmedTask
        var agent = Agent(projectID: projectID, provider: r.provider, model: r.model, effort: r.effort, access: r.access,
                          role: r.role.trimmingCharacters(in: .whitespacesAndNewlines),
                          cwd: cwd, branch: branch, pendingTask: prompt.isEmpty ? nil : prompt)
        agent.issue = r.issue
        if r.planMode && r.provider == .claude { agent.startsInPlan = true }
        // An issue already has a title someone wrote, and so does a split's task, so neither needs one from Haiku.
        if let issue = r.issue { agent.title = Agent.roughTitle(issue.title) } else if let title = r.title { agent.title = Agent.roughTitle(title) }
        else if !t.isEmpty { agent.title = Agent.roughTitle(t) }
        return agent
    }

    /// Whether to ask Haiku for a better title once the agent exists.
    package static func wantsGeneratedTitle(_ r: NewAgent) -> Bool {
        r.issue == nil && r.title == nil && !r.trimmedTask.isEmpty
    }

    /// The whole thing for a host: its own branch if asked (a git worktree), then the agent. The request is the
    /// first prompt as it is (attachments are the app's).
    package static func create(_ r: NewAgent, in project: Project, git: String?) async throws -> Agent {
        var cwd = project.path
        var branch: String?
        if r.ownBranch {
            (cwd, branch) = try await Git.makeWorktree(git: git, project: project, slug: branchSlug(r))
        }
        return make(r, projectID: project.id, cwd: cwd, branch: branch, prompt: r.trimmedTask)
    }
}

/// A short title for a chat, written by Haiku from its first request.
package enum ChatTitle {
    package static func question(for prompt: String) -> String {
        "Write a short title (3 to 6 words, no quotes, no trailing period) for a coding chat that starts "
            + "with this request. Reply with only the title.\n\nRequest: \(prompt.prefix(2000))"
    }

    /// Asks Claude Code (`claude -p`, Haiku, no tools, nothing saved). Nil when it fails or the answer doesn't
    /// look like a title. `extraArgs` carries API-key settings when Claude signs in with a key.
    package static func ask(claude: String, prompt: String, extraArgs: [String] = [], cwd: String,
                            env: [String: String] = [:]) async -> String? {
        // The prompt goes before the flags: --tools takes every word after it.
        let r = await Shell.run(claude, ["-p", question(for: prompt), "--model", "haiku", "--no-session-persistence"] + extraArgs + ["--tools", ""],
                                cwd: cwd, env: env)
        let title = r.out.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "\"'.")))
        guard r.ok, !title.isEmpty, title.count <= 80, !title.contains("\n") else { return nil }
        return title
    }
}
