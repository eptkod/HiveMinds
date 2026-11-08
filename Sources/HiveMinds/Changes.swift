import SwiftUI
import HiveMindsCore
import HiveMindsProtocol

// ChangeSet, ChangedFile, DiffLine and the git work behind them live in HiveMindsCore (`Git`).
extension AppStore {
    /// The files an agent changed, with line counts. Runs git in the background, so the window keeps responding.
    func changes(of agent: Agent) async throws -> ChangeSet {
        if let host = remoteHost(of: agent.id) { return try await remoteChanges(agent.id, on: host) }
        return try await Git.changes(git: tools.git, of: agent, projectPath: project(agent.projectID)?.path,
                              transcripts: spend.entries[agent.id]?.transcripts ?? [])
    }

    /// One file's diff, cut off after `limit` lines so a huge file can't stall the window.
    func diff(of agent: Agent, file: ChangedFile, against set: ChangeSet, limit: Int = 3000) async -> (lines: [DiffLine], cut: Bool) {
        if let host = remoteHost(of: agent.id) { return await remoteDiff(agent.id, file: file, against: set, on: host) }
        return await Git.diff(git: tools.git, cwd: agent.cwd, file: file, against: set, limit: limit)
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
