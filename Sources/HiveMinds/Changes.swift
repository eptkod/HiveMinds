import SwiftUI

/// What an agent has changed: on its own branch, everything since it left the branch it came from
/// (commits and uncommitted work alike); in the project folder, whatever isn't committed yet in the files
/// it edited itself, since other agents may be working in the same folder.
struct ChangeSet {
    /// What the changes are measured against, in words: "main", "the last commit".
    var base: String
    /// The commit the diff is taken from.
    var baseRef: String
    var files: [ChangedFile]
    /// In the project folder, true when `files` is cut down to the ones the agent edited. False when that
    /// can't be known (a Codex agent), so the list is everything uncommitted in the folder.
    var onlyItsOwn = false

    var added: Int { files.reduce(0) { $0 + ($1.added ?? 0) } }
    var removed: Int { files.reduce(0) { $0 + ($1.removed ?? 0) } }
}

struct ChangedFile: Identifiable, Hashable {
    var path: String
    /// Nil for a binary file, which has no line counts.
    var added: Int?
    var removed: Int?
    /// New and not yet known to git, so it has no diff of its own.
    var untracked = false
    var id: String { path }
}

/// One line of a diff, ready to colour.
struct DiffLine: Identifiable {
    enum Kind { case added, removed, context, hunk, meta }
    let id: Int
    let kind: Kind
    let text: String
}

extension AppStore {
    struct ChangesError: LocalizedError {
        var errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// The files an agent changed, with line counts. Runs git in the background, so the window keeps responding.
    func changes(of agent: Agent) async throws -> ChangeSet {
        guard let git = tools.git else { throw ChangesError("git isn't installed.") }
        guard FileManager.default.fileExists(atPath: agent.cwd) else { throw ChangesError("Its folder is gone: \(agent.cwd)") }
        let cwd = agent.cwd
        var base = "the last commit"
        var baseRef = "HEAD"
        if agent.branch != nil, let project = project(agent.projectID) {
            // The branch the project folder is on is where the agent's branch came from.
            let from = await Shell.run(git, ["-C", project.path, "rev-parse", "--abbrev-ref", "HEAD"])
            let name = from.out.trimmingCharacters(in: .whitespacesAndNewlines)
            if from.ok, !name.isEmpty, name != "HEAD", name != agent.branch {
                let fork = await Shell.run(git, ["merge-base", name, "HEAD"], cwd: cwd)
                let sha = fork.out.trimmingCharacters(in: .whitespacesAndNewlines)
                if fork.ok, !sha.isEmpty { base = name; baseRef = sha }
            }
        }
        let numstat = await Shell.run(git, ["diff", "--numstat", "--no-renames", baseRef], cwd: cwd)
        guard numstat.ok else { throw ChangesError("Couldn't read its changes. \(numstat.message)") }
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
            let transcripts = spend.entries[agent.id]?.transcripts ?? []
            let edited = await EditedFiles.shared.edits(agent.id, transcripts: transcripts)
            let root = (cwd as NSString).standardizingPath + "/"
            files = files.filter { edited.touched(root + $0.path, relative: $0.path) }
            onlyItsOwn = true
        }
        return ChangeSet(base: base, baseRef: baseRef, files: files.sorted { $0.path < $1.path }, onlyItsOwn: onlyItsOwn)
    }

    /// One file's diff, cut off after `limit` lines so a huge file can't stall the window.
    func diff(of agent: Agent, file: ChangedFile, against set: ChangeSet, limit: Int = 3000) async -> (lines: [DiffLine], cut: Bool) {
        guard let git = tools.git else { return ([], false) }
        let raw: String
        if file.untracked {
            let text = (try? String(contentsOfFile: agent.cwd + "/" + file.path, encoding: .utf8)) ?? ""
            raw = text.split(separator: "\n", omittingEmptySubsequences: false).map { "+" + $0 }.joined(separator: "\n")
        } else {
            raw = await Shell.run(git, ["diff", "--no-color", "--no-renames", set.baseRef, "--", file.path], cwd: agent.cwd).out
        }
        return await Task.detached {
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
                // The file header repeats what the list already says.
                if kind == .meta { continue }
                lines.append(DiffLine(id: lines.count, kind: kind, text: s))
            }
            return (lines, cut)
        }.value
    }
}

/// What a Claude Code agent wrote to: the files its Edit, Write, MultiEdit and NotebookEdit calls name,
/// plus its shell commands that write something. A command counts for a file when it names that file,
/// other than to run it (`scripts/build.sh` running a build doesn't change the script).
struct Edits: Sendable {
    var paths: Set<String> = []
    var commands: [String] = []

    func touched(_ path: String, relative: String) -> Bool {
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
actor EditedFiles {
    static let shared = EditedFiles()
    private var offsets: [String: UInt64] = [:]
    private var edited: [UUID: Edits] = [:]
    /// Signs that a shell command writes a file: a redirect to a file, an in-place edit, a move or copy,
    /// or a script opening a file for writing.
    private static let writes = try! NSRegularExpression(pattern:
        #"(?<![0-9&])>>?\s*(?!&|/dev/)|\b(sed|perl)\s+-p?i|\b(tee|mv|cp|rm|patch|touch)\s|git\s+(apply|checkout|restore)|\.write(_text)?\(|open\([^)]*['"][wa]\+?['"]|writeFileSync|\bcat\s*<<"#)

    func edits(_ id: UUID, transcripts: [String]) -> Edits {
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

/// Opens an agent's changes, with how many lines it added and removed: "+500 −20".
/// The count is read again only when the agent's status changes (a turn ending, say), so nothing polls.
struct ChangesButton: View {
    @Environment(AppStore.self) private var store
    let agent: Agent
    @State private var counts: (added: Int, removed: Int)?

    var body: some View {
        if store.canShowChanges(agent) {
            Button { store.showingChanges = agent } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plusminus")
                    if let counts, counts.added + counts.removed > 0 {
                        Text("+\(counts.added)").foregroundStyle(.green)
                        Text("−\(counts.removed)").foregroundStyle(.red)
                    }
                }
                .font(.caption.monospacedDigit())
                .fixedSize()
                .contentTransition(.numericText())
                .animation(Motion.press, value: counts?.added)
            }
            .buttonStyle(.borderless)
            .help(help)
            .task(id: store.state(agent.id).status) {
                guard let set = try? await store.changes(of: agent) else { return }
                counts = (set.added, set.removed)
            }
        }
    }

    private var help: String {
        guard let counts, counts.added + counts.removed > 0 else { return "Show changes. Nothing changed yet." }
        let note = agent.branch == nil && agent.provider != .claude ? ", counting every agent's work in the project folder" : ""
        return "Show changes: \(counts.added) lines added, \(counts.removed) removed\(note)"
    }
}

/// A read-only look at what an agent changed: the files on the left, the picked file's diff on the right.
struct ChangesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let agent: Agent

    @State private var set: ChangeSet?
    @State private var error: String?
    @State private var picked: ChangedFile?
    @State private var lines: [DiffLine] = []
    @State private var cut = false
    @State private var loadingDiff = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider().overlay(Theme.hairline)
            content
        }
        .frame(width: 960, height: 620)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Changes").font(.title3.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let set, !set.files.isEmpty {
                HStack(spacing: 6) {
                    Text("\(set.files.count) \(set.files.count == 1 ? "file" : "files")").foregroundStyle(.secondary)
                    Text("+\(set.added)").foregroundStyle(.green)
                    Text("−\(set.removed)").foregroundStyle(.red)
                }
                .font(.callout.monospacedDigit())
            }
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Look again")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var subtitle: String {
        let what = agent.title
        guard let set else { return what }
        if agent.branch != nil { return "\(what) · \(agent.branch!) compared with \(set.base)" }
        if set.onlyItsOwn { return "\(what) · not committed yet, in the files it edited in the project folder" }
        return "\(what) · not committed yet in the project folder, which can include changes from others"
    }

    @ViewBuilder private var content: some View {
        if let error {
            Text(error).foregroundStyle(.red).textSelection(.enabled)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let set {
            if set.files.isEmpty {
                Text("Nothing has changed yet.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    fileList(set)
                        .frame(width: 300)
                    Divider().overlay(Theme.hairline)
                    diffView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking at its changes…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func fileList(_ set: ChangeSet) -> some View {
        List(set.files, selection: Binding(get: { picked }, set: { f in if let f { pick(f) } })) { f in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((f.path as NSString).lastPathComponent).lineLimit(1)
                    let dir = (f.path as NSString).deletingLastPathComponent
                    if !dir.isEmpty {
                        Text(dir).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if f.untracked { Text("new").font(.caption).foregroundStyle(.secondary) }
                if let a = f.added, let r = f.removed {
                    Text("+\(a)").foregroundStyle(.green).font(.caption.monospacedDigit())
                    if r > 0 { Text("−\(r)").foregroundStyle(.red).font(.caption.monospacedDigit()) }
                } else {
                    Text("binary").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .help(f.path)
            .tag(f)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var diffView: some View {
        if picked == nil {
            Text("Pick a file to see what changed in it.").foregroundStyle(.secondary)
        } else if loadingDiff {
            ProgressView().controlSize(.small)
        } else if lines.isEmpty {
            Text(picked?.added == nil ? "This is a binary file, so there's nothing to show." : "No differences to show.")
                .foregroundStyle(.secondary)
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(color(line.kind))
                            .padding(.horizontal, 12)
                            .padding(.vertical, line.kind == .hunk ? 4 : 0)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line.kind))
                    }
                    if cut {
                        Text("Cut short here. The full diff is too long to show.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                }
                .padding(.vertical, 8)
                .textSelection(.enabled)
            }
            // A short diff sits at the top left, not in the middle.
            .defaultScrollAnchor(.topLeading)
        }
    }

    private func color(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: Color(red: 0.55, green: 0.9, blue: 0.6)
        case .removed: Color(red: 1, green: 0.55, blue: 0.55)
        case .hunk: .secondary
        case .context, .meta: .primary.opacity(0.75)
        }
    }

    private func background(_ k: DiffLine.Kind) -> Color {
        switch k {
        case .added: .green.opacity(0.08)
        case .removed: .red.opacity(0.08)
        case .hunk: Theme.surface
        case .context, .meta: .clear
        }
    }

    private func load() async {
        error = nil
        do {
            let s = try await store.changes(of: agent)
            set = s
            // Keep the same file open after looking again, if it's still there.
            if let p = picked, let same = s.files.first(where: { $0.path == p.path }) { pick(same) }
            else if let first = s.files.first { pick(first) }
            else { picked = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pick(_ f: ChangedFile) {
        guard let set else { return }
        picked = f
        loadingDiff = true
        Task {
            let r = await store.diff(of: agent, file: f, against: set)
            // A newer pick may have landed while this one was reading.
            guard picked == f else { return }
            lines = r.lines
            cut = r.cut
            loadingDiff = false
        }
    }
}
