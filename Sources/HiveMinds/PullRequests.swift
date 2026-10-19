import Foundation

/// The pull request for an agent's branch, once there is one.
struct PullRequestRef: Codable, Hashable {
    var number: Int
    var url: String
    /// OPEN, MERGED or CLOSED, as GitHub says it.
    var state: String

    var label: String {
        switch state {
        case "MERGED": "Merged"
        case "CLOSED": "Closed"
        default: "Open"
        }
    }
}

/// What a pull request for an agent's branch would contain, gathered before anything is pushed.
struct PRPlan {
    var base: String
    var branch: String
    /// Commit subjects on the branch that aren't on the base yet.
    var commits: [String]
    /// Commits made since the branch was last pushed (all of them, if it never was).
    var unpushed: Int
    /// `git status --porcelain` lines: changes not committed yet.
    var uncommitted: [String]

    var hasChanges: Bool { !commits.isEmpty || !uncommitted.isEmpty }
}

extension AppStore {
    struct PRError: LocalizedError {
        var errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Looks at the agent's branch: what it changed, and where a pull request would go.
    func planPullRequest(_ agent: Agent) async throws -> PRPlan {
        guard let git = tools.git else { throw PRError("git isn't installed.") }
        guard let gh = tools.gh else { throw PRError("The GitHub CLI (gh) isn't installed. Connect GitHub first.") }
        guard let branch = agent.branch else { throw PRError("This agent works in the project folder, not on its own branch.") }
        let cwd = agent.cwd
        let repo = await Shell.run(gh, ["repo", "view", "--json", "defaultBranchRef", "--jq", ".defaultBranchRef.name"], cwd: cwd)
        let base = repo.out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard repo.ok, !base.isEmpty else {
            throw PRError("This project isn't on GitHub, or you aren't signed in. \(repo.message)")
        }
        // Compare with GitHub's copy of the base, so the list matches what the pull request will show.
        _ = await Shell.run(git, ["fetch", "--quiet", "origin", base], cwd: cwd)
        let log = await Shell.run(git, ["log", "--format=%s", "origin/\(base)..HEAD"], cwd: cwd)
        let commits = log.out.split(separator: "\n").map(String.init)
        let status = await Shell.run(git, ["status", "--porcelain"], cwd: cwd)
        let uncommitted = status.out.split(separator: "\n").map(String.init)
        let ahead = await Shell.run(git, ["rev-list", "--count", "@{u}..HEAD"], cwd: cwd)
        let unpushed = ahead.ok ? Int(ahead.out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 : commits.count
        return PRPlan(base: base, branch: branch, commits: commits, unpushed: unpushed, uncommitted: uncommitted)
    }

    /// A title and description written by Haiku from the branch's changes. Nil if that fails.
    func draftPullRequest(_ agent: Agent, _ plan: PRPlan) async -> (title: String, body: String)? {
        guard let claude = tools.claude, let git = tools.git else { return nil }
        let stat = await Shell.run(git, ["diff", "--stat", "origin/\(plan.base)"], cwd: agent.cwd)
        let diff = await Shell.run(git, ["diff", "origin/\(plan.base)"], cwd: agent.cwd)
        let ask = """
        Write a GitHub pull request for these changes. First line: a short title (under 70 characters, no quotes, \
        no trailing period). Then a blank line. Then a description in Markdown: a one-sentence summary, then a short \
        bullet list of the main changes. Plain language. Reply with only the title and description.

        What the agent was asked to do: \(agent.title)

        Commits:
        \(plan.commits.joined(separator: "\n"))

        Not committed yet:
        \(plan.uncommitted.joined(separator: "\n"))

        Files changed:
        \(stat.out)

        Diff (may be cut short):
        \(diff.out.prefix(30_000))
        """
        // The prompt goes before the flags: --tools takes every word after it.
        let r = await Shell.run(claude, ["-p", ask, "--model", "haiku", "--no-session-persistence"] + claudeKeyArgs + ["--tools", ""],
                                cwd: supportDir.path, env: SignIn.environment(for: .claude))
        guard r.ok else { return nil }
        let text = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first else { return nil }
        let title = first.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "#\"'")))
        let body = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        guard !title.isEmpty, title.count <= 120 else { return nil }
        return (title, body)
    }

    /// Commits anything left, pushes the branch, and opens the pull request (or, if one is open, just pushes).
    func publishPullRequest(_ agent: Agent, plan: PRPlan, title: String, body: String, draft: Bool) async throws {
        guard let git = tools.git, let gh = tools.gh else { throw PRError("git and the GitHub CLI are needed.") }
        let cwd = agent.cwd
        if !plan.uncommitted.isEmpty {
            let add = await Shell.run(git, ["add", "-A"], cwd: cwd)
            guard add.ok else { throw PRError("Couldn't stage the changes. \(add.message)") }
            let message = title.isEmpty ? agent.title : title
            let commit = await Shell.run(git, ["commit", "-m", message], cwd: cwd)
            guard commit.ok else { throw PRError("Couldn't commit the changes. \(commit.message)") }
        }
        let push = await Shell.run(git, ["push", "-u", "origin", plan.branch], cwd: cwd)
        guard push.ok else { throw PRError("Couldn't push the branch to GitHub. \(push.message)") }

        if agent.pullRequest?.state != "OPEN" {
            let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent("hiveminds-pr-\(UUID().uuidString).md")
            try? body.write(to: bodyFile, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: bodyFile) }
            var args = ["pr", "create", "--base", plan.base, "--head", plan.branch, "--title", title, "--body-file", bodyFile.path]
            if draft { args.append("--draft") }
            let create = await Shell.run(gh, args, cwd: cwd)
            guard create.ok else { throw PRError("Couldn't open the pull request. \(create.message)") }
        }
        await refreshPullRequest(agent.id)
    }

    /// Finds the pull request for the agent's branch, including one the agent opened itself.
    func refreshPullRequest(_ id: UUID) async {
        guard let agent = agent(id), let branch = agent.branch, agent.meetingID == nil, let gh = tools.gh,
              FileManager.default.fileExists(atPath: agent.cwd) else { return }
        let r = await Shell.run(gh, ["pr", "list", "--head", branch, "--state", "all", "--limit", "1",
                                     "--json", "number,url,state"], cwd: agent.cwd)
        guard r.ok, let found = try? JSONDecoder().decode([PullRequestRef].self, from: Data(r.out.utf8)) else { return }
        if found.first != agent.pullRequest { update(id) { $0.pullRequest = found.first } }
    }
}
