import Foundation

/// One job for one agent, as the split's planner wrote it.
struct SplitTask: Decodable {
    var title: String
    var prompt: String
    var model: String
    var effort: String
    /// Which attached files belong to it, numbered from 1 as listed in the planner's prompt.
    var attachments: [Int]?
    /// The main files it will touch, so its agent can start there.
    var files: [String]?
}

extension AppStore {
    /// Splits a request with several things in it (say, six bugs from a play test) across agents.
    /// Sonnet looks at the code read-only and groups problems that share files, so no two agents read
    /// the same code or clash, and picks the cheapest model that will do each one. The agents start in
    /// the background and show on the project's Canvas. If planning fails, the request starts as one agent.
    /// `model` and `effort` are nil for Auto: each agent gets what the planner picked.
    func splitUp(projectID: UUID, provider: Provider, model: String?, effort: Effort?, access: Access, planMode: Bool,
                 role: String, request: String, attachments: [Attachment], ownBranch: Bool) {
        guard let project = project(projectID) else { return }
        notice = "Splitting your request into agents…"
        Task {
            // Saved inside the project first, so the planner can open the screenshots to see which problem each one shows.
            let folder = URL(filePath: project.path).appending(path: ".hiveminds/attachments/split-\(UUID().uuidString.prefix(8).lowercased())")
            var paths: [String] = []
            if !attachments.isEmpty {
                excludeFromGit(project: project, pattern: "/.hiveminds/")
                paths = (try? Attachment.save(attachments, to: folder)) ?? []
            }
            defer { try? FileManager.default.removeItem(at: folder) }

            let tasks = await planSplit(project: project, request: request, paths: paths)
            func start(_ task: String, title: String?, model: String, effort: Effort, files: [Attachment]) async throws {
                try await createAgent(projectID: projectID, provider: provider, model: provider == .claude ? model : "default",
                                      effort: effort, access: access, planMode: planMode, role: role, task: task,
                                      attachments: files, ownBranch: ownBranch, title: title, open: false)
            }

            guard let tasks, !tasks.isEmpty else {
                do {
                    try await start(request, title: nil, model: model ?? AgentDefaults.model, effort: effort ?? AgentDefaults.effort, files: attachments)
                    notice = "Couldn't split that up, so it started as one agent in \(project.name)."
                } catch { errorMessage = error.localizedDescription }
                showCanvas(projectID)
                return
            }

            var started: [String] = []
            for (i, task) in tasks.enumerated() {
                let others = tasks.indices.filter { $0 != i }.map { "- \(tasks[$0].title)" }
                var prompt = task.prompt
                if let files = task.files, !files.isEmpty { prompt += "\n\nStart with: " + files.joined(separator: ", ") }
                if !others.isEmpty {
                    prompt += "\n\nOther agents are working on these at the same time, so leave them to it:\n" + others.joined(separator: "\n")
                }
                let mine = (task.attachments ?? []).compactMap { paths.indices.contains($0 - 1) ? Attachment(file: URL(filePath: paths[$0 - 1])) : nil }
                let picked = Provider.claude.models.contains(task.model) ? task.model : AgentDefaults.model
                do {
                    try await start(prompt, title: task.title, model: model ?? picked,
                                    effort: effort ?? Effort(rawValue: task.effort) ?? AgentDefaults.effort, files: mine)
                    started.append(task.title)
                } catch { errorMessage = error.localizedDescription }
            }
            showCanvas(projectID)
            switch started.count {
            case 0: break
            case 1: notice = "That's one job, so one agent started: \(started[0])."
            default: notice = "Started \(started.count) agents in \(project.name): \(started.joined(separator: ", "))."
            }
        }
    }

    private func showCanvas(_ projectID: UUID) {
        mode = .agents
        selection = .project(projectID)
    }

    /// Asks Sonnet, with read-only tools, how to split the request. Nil if it fails or returns nothing usable.
    private func planSplit(project: Project, request: String, paths: [String]) async -> [SplitTask]? {
        guard let claude = tools.claude else { return nil }
        let max = AgentDefaults.splitMax
        let files = paths.isEmpty ? "" : "\n\nAttached files:\n"
            + paths.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let ask = """
        You're triaging a request for a team of coding agents that work in this project (the current folder). \
        Split it into tasks, one agent each, so the work gets done well for the fewest tokens.

        Rules:
        - One task per independent problem. Put problems in the same task when they touch the same files or system, \
        or depend on each other, since two agents would read the same code twice and their edits could clash.
        - Never split one problem across tasks. If the request is really one thing, return one task.
        - Return at most \(max) tasks. If there are more problems than that, group the closest ones.
        - Look at the code only enough to know where each problem lives: a few searches and reads. \
        Don't work out the fix; the agents will.
        - prompt: all its agent will see, so it must stand alone. Keep the user's own words and details for its problems, \
        say which files and functions to look at first, and add anything you found that saves it searching. \
        Write it to the agent, as the user would.
        - title: 3 to 6 words, no quotes, no trailing period.
        - model: the cheapest that will reliably do it. haiku for an obvious one- or two-line fix, sonnet for a normal bug \
        or feature, opus for hard or cross-cutting work, fable only for the hardest problems.
        - effort: low, medium, high or xhigh, for how much thinking it needs.
        - attachments: the numbers of the attached files that belong to this task (open images to see what they show). \
        A file can go to several tasks.
        - files: the main files it will touch, as paths relative to the project.\(files)

        Request:
        \(request)
        """
        let schema: [String: Any] = [
            "type": "object", "required": ["tasks"],
            "properties": ["tasks": [
                "type": "array", "minItems": 1, "maxItems": max,
                "items": [
                    "type": "object", "required": ["title", "prompt", "model", "effort"],
                    "properties": [
                        "title": ["type": "string"],
                        "prompt": ["type": "string"],
                        "model": ["type": "string", "enum": ["haiku", "sonnet", "opus", "fable"]],
                        "effort": ["type": "string", "enum": ["low", "medium", "high", "xhigh"]],
                        "attachments": ["type": "array", "items": ["type": "integer"]],
                        "files": ["type": "array", "items": ["type": "string"]],
                    ],
                ],
            ]],
        ]
        guard let schemaData = try? JSONSerialization.data(withJSONObject: schema),
              let schemaText = String(data: schemaData, encoding: .utf8) else { return nil }
        let model = ProcessInfo.processInfo.environment["HIVEMINDS_SPLIT_MODEL"] ?? "sonnet"
        // The prompt goes before the flags: --tools takes every word after it.
        let r = await Shell.run(claude, ["-p", ask, "--model", model, "--effort", "low", "--output-format", "json",
                                         "--json-schema", schemaText, "--no-session-persistence"]
                                    + claudeKeyArgs + ["--tools", "Read", "Glob", "Grep"],
                                cwd: project.path, env: SignIn.environment(for: .claude))
        guard r.ok, let data = r.out.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = result["structured_output"],
              let outputData = try? JSONSerialization.data(withJSONObject: output) else { return nil }
        struct Plan: Decodable { var tasks: [SplitTask] }
        let tasks = (try? JSONDecoder().decode(Plan.self, from: outputData))?.tasks
            .filter { !$0.title.isEmpty && !$0.prompt.isEmpty }
        return tasks.map { Array($0.prefix(max)) }
    }
}
