import Foundation

/// A message for someone to read, from the shared core.
package struct CoreError: LocalizedError, Sendable {
    package var message: String
    package init(_ message: String) { self.message = message }
    package var errorDescription: String? { message }
}

/// Git work for agents: their own branches (worktrees), and what they changed. Runs git as a separate process.
package enum Git {
    /// A new git worktree on its own branch, `hive/<slug>`, inside the project. Returns its folder and branch.
    package static func makeWorktree(git: String?, project: Project, slug: String) async throws -> (path: String, branch: String) {
        guard let git else { throw CoreError("git isn't installed, so the agent can't get its own branch.") }
        guard project.isGitRepo else { throw CoreError("\(project.name) isn't a git repository, so the agent can't get its own branch. Turn off \"Own branch\".") }
        let branch = "hive/\(slug)"
        // Inside the project, like Agent Office: trusting the project in Claude Code then covers every
        // agent's folder, so new agents don't stop at Claude Code's "trust this folder?" question.
        let path = "\(project.path)/.hiveminds/worktrees/\(slug)"
        excludeFromGit(projectPath: project.path, pattern: "/.hiveminds/")
        let r = await Shell.run(git, ["-C", project.path, "worktree", "add", "-b", branch, path])
        guard r.ok else {
            let hint = r.message.contains("invalid reference") || r.message.contains("not a valid object")
                ? " The repository has no commits yet. Make a first commit, or turn off \"Own branch\"." : ""
            throw CoreError("Couldn't make a branch for the agent. \(r.message)\(hint)")
        }
        return (path, branch)
    }

    /// Keeps the agents' folders out of `git status` without changing any file in the repository.
    package static func excludeFromGit(projectPath: String, pattern: String) {
        let file = "\(projectPath)/.git/info/exclude"
        let current = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(Substring(pattern)) else { return }
        try? FileManager.default.createDirectory(atPath: "\(projectPath)/.git/info", withIntermediateDirectories: true)
        let line = (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + pattern + "\n"
        try? (current + line).write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// The files an agent changed, with line counts. `projectPath` is the project folder (needed for an agent
    /// on its own branch); `transcripts` are its Claude Code transcripts (for one working in the project folder).
    package static func changes(git: String?, of agent: Agent, projectPath: String?, transcripts: [String]) async throws -> ChangeSet {
        guard let git else { throw CoreError("git isn't installed.") }
        guard FileManager.default.fileExists(atPath: agent.cwd) else { throw CoreError("Its folder is gone: \(agent.cwd)") }
        let cwd = agent.cwd
        var base = "the last commit"
        var baseRef = "HEAD"
        if agent.branch != nil, let projectPath {
            // The branch the project folder is on is where the agent's branch came from.
            let from = await Shell.run(git, ["-C", projectPath, "rev-parse", "--abbrev-ref", "HEAD"])
            let name = from.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if from.ok, !name.isEmpty, name != "HEAD", name != agent.branch {
                let fork = await Shell.run(git, ["merge-base", name, "HEAD"], cwd: cwd)
                let sha = fork.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if fork.ok, !sha.isEmpty { base = name; baseRef = sha }
            }
        }
        let numstat = await Shell.run(git, ["diff", "--numstat", "--no-renames", baseRef], cwd: cwd)
        guard numstat.ok else { throw CoreError("Couldn't read its changes. \(numstat.message)") }
        var files = numstat.out.split(separator: "\n").compactMap { line -> ChangedFile? in
            let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { return nil }
            return ChangedFile(path: parts[2], added: Int(parts[0]), removed: Int(parts[1]))
        }
        let others = await Shell.run(git, ["ls-files", "--others", "--exclude-standard"], cwd: cwd)
        for path in others.out.split(separator: "\n").map(String.init) where !path.isEmpty {
            let text = try? String(contentsOfFile: cwd + "/" + path, encoding: .utf8)
            files.append(ChangedFile(path: path, added: text.map { $0.split(separator: "\n", omittingEmptySubsequences: false).count }, removed: text == nil ? nil : 0, untracked: true))
        }
        var onlyItsOwn = false
        if agent.branch == nil, agent.provider == .claude {
            // Git can't tell agents in one folder apart, so keep only what this one wrote to.
            let edited = await EditedFiles.shared.edits(agent.id, transcripts: transcripts)
            let root = (cwd as NSString).standardizingPath + "/"
            files = files.filter { edited.touched(root + $0.path, relative: $0.path) }
            onlyItsOwn = true
        }
        return ChangeSet(base: base, baseRef: baseRef, files: files.sorted { $0.path < $1.path }, onlyItsOwn: onlyItsOwn)
    }

    /// One file's diff, cut off after `limit` lines so a huge file can't stall whoever shows it.
    package static func diff(git: String?, cwd: String, file: ChangedFile, against set: ChangeSet, limit: Int = 3000) async -> (lines: [DiffLine], cut: Bool) {
        guard let git else { return ([], false) }
        let raw: String
        if file.untracked {
            let text = (try? String(contentsOfFile: cwd + "/" + file.path, encoding: .utf8)) ?? ""
            raw = text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        } else {
            raw = await Shell.run(git, ["diff", "--no-color", "--no-renames", set.baseRef, "--", file.path], cwd: cwd).out
        }
        return await Task.detached { parseDiff(raw, limit: limit) }.value
    }

    /// Diff text as coloured lines, without the file header (the list already says it).
    package static func parseDiff(_ raw: String, limit: Int) -> (lines: [DiffLine], cut: Bool) {
        var lines: [DiffLine] = []
        var cut = false
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.count >= limit { cut = true; break }
            let s = String(line)
            let kind: DiffLine.Kind
            if s.hasPrefix("+++") || s.hasPrefix("---") || s.hasPrefix("diff ") || s.hasPrefix("index ")
                || s.hasPrefix("new file") || s.hasPrefix("deleted file") || s.hasPrefix("Binary") || s.hasPrefix("\\") {
                kind = .meta
            } else if s.hasPrefix("@@") { kind = .hunk }
            else if s.hasPrefix("+") { kind = .added }
            else if s.hasPrefix("-") { kind = .removed }
            else { kind = .context }
            if kind == .meta { continue }
            lines.append(DiffLine(id: lines.count, kind: kind, text: s))
        }
        return (lines, cut)
    }
}

/// What an agent has changed: on its own branch, everything since it left the branch it came from
/// (commits and uncommitted work alike); in the project folder, whatever isn't committed yet in the files
/// it edited itself, since other agents may be working in the same folder.
package struct ChangeSet: Sendable {
    /// What the changes are measured against, in words: "main", "the last commit".
    package var base: String
    /// The commit the diff is taken from.
    package var baseRef: String
    package var files: [ChangedFile]
    /// In the project folder, true when `files` is cut down to the ones the agent edited. False when that
    /// can't be known (a Codex agent), so the list is everything uncommitted in the folder.
    package var onlyItsOwn = false

    package init(base: String, baseRef: String, files: [ChangedFile], onlyItsOwn: Bool = false) {
        self.base = base
        self.baseRef = baseRef
        self.files = files
        self.onlyItsOwn = onlyItsOwn
    }

    package var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    package var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
}

package struct ChangedFile: Identifiable, Hashable, Sendable {
    package var path: String
    /// Nil for a binary file, which has no line counts.
    package var added: Int?
    package var removed: Int?
    /// New and not yet known to git, so it has no diff of its own.
    package var untracked = false
    package var id: String { path }

    package init(path: String, added: Int?, removed: Int?, untracked: Bool = false) {
        self.path = path
        self.added = added
        self.removed = removed
        self.untracked = untracked
    }
}

/// One line of a diff, ready to colour.
package struct DiffLine: Identifiable, Sendable {
    package enum Kind: Sendable { case added, removed, context, hunk, meta }
    package let id: Int
    package let kind: Kind
    package let text: String

    package init(id: Int, kind: Kind, text: String) {
        self.id = id
        self.kind = kind
        self.text = text
    }
}

/// What a Claude Code agent wrote to: the files its Edit, Write, MultiEdit and NotebookEdit calls name,
/// plus its shell commands that write something. A command counts for a file when it names that file,
/// other than to run it (`scripts/build.sh` running a build doesn't change the script).
package struct Edits: Sendable {
    package var paths: Set<String> = []
    package var commands: [String] = []

    package init(paths: Set<String> = [], commands: [String] = []) {
        self.paths = paths
        self.commands = commands
    }

    package func touched(_ path: String, relative: String) -> Bool {
        paths.contains(path) || commands.contains { Self.names($0, path) || Self.names($0, relative) }
    }

    private static func names(_ command: String, _ path: String) -> Bool {
        var from = command.startIndex
        while let r = command.range(of: path, range: from..<command.endIndex) {
            let before = command[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let runs = before.isEmpty || before.last.map { ";&|\n(".contains($0) } == true
                || ["bash", "sh", "zsh", "source", "."].contains { before.hasSuffix(" " + $0) || before == $0 }
            if !runs { return true }
            from = r.upperBound
        }
        return false
    }
}

/// Reads each agent's `Edits` from its transcripts (subagents' included). Remembers how far it got in each
/// file, so each look only reads what's new.
package actor EditedFiles {
    package static let shared = EditedFiles()
    private var offsets: [String: UInt64] = [:]
    private var edited: [UUID: Edits] = [:]
    /// Signs that a shell command writes a file: a redirect to a file, an in-place edit, a move or copy,
    /// or a script opening a file for writing.
    private static let writes = try! NSRegularExpression(pattern:
        #"(?<![0-9&])>>?\s*(?!&|/dev/)|\b(sed|perl)\s+-p?i|\b(tee|mv|cp|rm|patch|touch)\s|git\s+(apply|checkout|restore)|\.write(_text)?\(|open\([^)]*['"][wa]\+?['"]|writeFileSync|\bcat\s*<<"#)

    package init() {}

    package func edits(_ id: UUID, transcripts: [String]) -> Edits {
        var set = edited[id] ?? Edits()
        for path in transcripts {
            read(path, into: &set)
            let subagents = (path as NSString).deletingPathExtension + "/subagents"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: subagents)) ?? [] where name.hasSuffix(".jsonl") {
                read(subagents + "/" + name, into: &set)
            }
        }
        edited[id] = set
        return set
    }

    private func read(_ path: String, into set: inout Edits) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var offset = offsets[path] ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 0x0A) else { return }
        // Only whole lines; a line still being written is read next time.
        offsets[path] = offset + UInt64(end - data.startIndex + 1)
        let marker = Data(#""tool_use""#.utf8)
        for line in data[data.startIndex..<end].split(separator: 0x0A) where line.range(of: marker) != nil {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let blocks = (json["message"] as? [String: Any])?["content"] as? [[String: Any]] else { continue }
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let input = block["input"] as? [String: Any] else { continue }
                switch block["name"] as? String {
                case "Edit", "Write", "MultiEdit", "NotebookEdit":
                    if let file = input["file_path"] as? String ?? input["notebook_path"] as? String {
                        set.paths.insert((file as NSString).standardizingPath)
                    }
                case "Bash":
                    if let command = input["command"] as? String,
                       Self.writes.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil {
                        set.commands.append(command)
                    }
                default: break
                }
            }
        }
    }
}
