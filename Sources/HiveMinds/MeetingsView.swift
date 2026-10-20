import SwiftUI
import AppKit

/// The Meetings page: the formats and past meetings, or the open meeting room.
struct MeetingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if let id = store.meetingSelection, let meeting = store.meeting(id) {
                MeetingRoomView(meeting: meeting)
                    .id(id)
            } else {
                MeetingListView()
            }
        }
        .transition(Motion.enter)
        .animation(Motion.bouncy, value: store.meetingSelection)
        .confirmationDialog("Delete \(store.pendingDeleteMeeting.map { "\"\($0.title)\"" } ?? "meeting")?",
                            isPresented: Binding(get: { store.pendingDeleteMeeting != nil },
                                                 set: { if !$0 { store.pendingDeleteMeeting = nil } }),
                            presenting: store.pendingDeleteMeeting) { meeting in
            Button("Delete Meeting", role: .destructive) { Task { await store.deleteMeeting(meeting) } }
        } message: { meeting in
            Text(meeting.branch != nil
                 ? "Its agents stop and its notes are removed. Its branch \(meeting.branch!) and anything committed on it are kept."
                 : "Its agents stop. Files it wrote in the project are kept.")
        }
    }
}

// MARK: List

struct MeetingListView: View {
    @Environment(AppStore.self) private var store

    private var sorted: [Meeting] { store.meetings.sorted { $0.createdAt > $1.createdAt } }
    private var finished: [Meeting] {
        store.meetings.filter { $0.status == .finished }
            .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
    }

    var body: some View {
        HStack(spacing: 0) {
            list
            if !finished.isEmpty {
                Rectangle().fill(Theme.hairline).frame(width: 0.5)
                PastOutcomesSidebar(meetings: finished)
                    .frame(width: 290)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(Motion.bouncy, value: finished.isEmpty)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    PageHeader(title: "Meetings", subtitle: "Put several agents round a table on one question. They take turns, and the outcome is saved to your project.")
                    Button { store.beginNewMeeting() } label: { Label("New Meeting", systemImage: "plus") }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(store.projects.isEmpty)
                }

                if !sorted.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Meetings").font(.headline)
                        ForEach(sorted) { MeetingRow(meeting: $0) }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Formats").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14)], spacing: 14) {
                        ForEach(MeetingPattern.allCases) { p in
                            Button { store.beginNewMeeting(pattern: p) } label: {
                                Card {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Image(systemName: p.symbol).font(.title3).foregroundStyle(.secondary)
                                            .frame(height: 22, alignment: .leading)
                                        Text(p.name).font(.headline)
                                        Text(p.blurb).font(.callout).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                        Text(p.seatsLabel).font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.squish)
                            .disabled(store.projects.isEmpty)
                            .help("Start a \(p.name) meeting")
                        }
                    }
                }
                if store.projects.isEmpty {
                    Text("Meetings work inside a project. Add one from the sidebar first.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(32)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)
        }
    }
}

struct MeetingRow: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting

    var body: some View {
        Button { store.openMeeting(meeting.id) } label: {
            Card(padding: 14) {
                HStack(spacing: 14) {
                    Image(systemName: meeting.pattern.symbol)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(meeting.title).fontWeight(.medium).lineLimit(1)
                        Text([store.project(meeting.projectID)?.name, meeting.pattern.name, meeting.createdAt.relative]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 4) {
                        ForEach(meeting.seats, id: \.agentID) { seat in
                            StatusDot(status: store.state(seat.agentID).status, size: 6)
                        }
                    }
                    Text(meetingProgress(meeting))
                        .font(.caption)
                        .foregroundStyle(needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                        .frame(width: 170, alignment: .trailing)
                    Text(meetingSpend(meeting))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 60, alignment: .trailing)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.orange.opacity(needsYou ? 0.6 : 0), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Open") { store.openMeeting(meeting.id) }
            if meeting.status == .running {
                Button("Pause") { store.pauseMeeting(meeting.id) }
            } else if meeting.status == .paused {
                Button("Resume") { store.resumeMeeting(meeting.id) }
            }
            Divider()
            Button("Delete Meeting…", role: .destructive) { store.pendingDeleteMeeting = meeting }
        }
    }

    private var needsYou: Bool { meeting.seats.contains { store.state($0.agentID).status == .needsYou } }
}

/// Finished meetings and what they came to, newest first: a few lines from each outcome document.
struct PastOutcomesSidebar: View {
    @Environment(AppStore.self) private var store
    let meetings: [Meeting]
    /// Summaries by meeting, read from disk off the main thread. Missing means the document isn't there.
    @State private var summaries: [UUID: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Past outcomes").font(.headline)
                    .padding(.bottom, 2)
                ForEach(meetings) { m in
                    Button { store.openMeeting(m.id, tab: .outcome) } label: { entry(m) }
                        .buttonStyle(.squish)
                        .help("Open the outcome of \(m.title)")
                        .contextMenu {
                            Button("Show in Finder") { store.revealFile(m.outcomeURL) }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 32)
        }
        .task(id: meetings.map(\.id)) {
            let files = meetings.map { ($0.id, $0.outcomeURL) }
            summaries = await Task.detached {
                var found: [UUID: String] = [:]
                for (id, url) in files {
                    if let text = try? String(contentsOf: url, encoding: .utf8) { found[id] = outcomeSummary(text) }
                }
                return found
            }.value
        }
    }

    private func entry(_ m: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: m.pattern.symbol).font(.caption).foregroundStyle(.secondary)
                Text(m.title).font(.callout.weight(.medium)).lineLimit(1)
            }
            Text(summaries[m.id] ?? "No outcome document found.")
                .font(.caption)
                .foregroundStyle(summaries[m.id] == nil ? .tertiary : .secondary)
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            Text([store.project(m.projectID)?.name, (m.finishedAt ?? m.createdAt).relative, m.posted ? "posted" : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// The gist of an outcome document as plain text: the section that says what was decided if there is one,
/// otherwise the first paragraph.
nonisolated func outcomeSummary(_ markdown: String) -> String {
    let lines = markdown.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    let keys = ["decision", "decided", "verdict", "conclusion", "summary", "outcome", "result"]
    // Skip the document's title: a heading named "Decision: …" says nothing about what was decided.
    let start = lines.indices.dropFirst().first { i in
        lines[i].hasPrefix("#") && keys.contains { lines[i].lowercased().contains($0) }
    }.map { $0 + 1 } ?? 0
    var picked: [String] = []
    for line in lines[start...] {
        if line.hasPrefix("#") || line.hasPrefix("---") || line.hasPrefix("|") || line.hasPrefix("```") {
            if picked.isEmpty { continue } else { break }
        }
        if line.isEmpty { if picked.isEmpty { continue } else { break } }
        var text = line
        for marker in ["- ", "* ", "> "] where text.hasPrefix(marker) { text.removeFirst(marker.count) }
        picked.append(text)
        if picked.joined(separator: " ").count > 320 { break }
    }
    let joined = picked.joined(separator: " ")
    let plain = (try? AttributedString(markdown: joined, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        .map { String($0.characters) } ?? joined
    return plain.isEmpty ? "The outcome document is empty." : plain
}

/// "Step 2 of 4 · Critique", "Paused at step 2 of 4" or "Finished".
func meetingProgress(_ m: Meeting) -> String {
    let steps = m.plan()
    switch m.status {
    case .running:
        guard m.step < steps.count else { return "Wrapping up" }
        return "Step \(m.step + 1) of \(steps.count) · \(steps[m.step].title)"
    case .paused:
        return "Paused at step \(min(m.step + 1, steps.count)) of \(steps.count)"
    case .finished:
        return "Finished"
    }
}

/// Cost so far, or nothing before any is known.
func meetingSpend(_ m: Meeting) -> String {
    m.totalCost > 0 ? String(format: "$%.2f", m.totalCost) : ""
}

// MARK: New meeting

/// Pick a format, say what it's about, and start. Seats, rounds and model have defaults from Settings.
struct NewMeetingSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: UUID?
    @State private var projectGiven = false
    @State private var pattern: MeetingPattern = .debate
    @State private var topic = ""
    @State private var seats = 3
    @State private var rounds = 2
    @State private var model = "default"
    @State private var splitModels = false
    @State private var otherModel = "sonnet"
    @State private var prNumber = ""
    @State private var openPRs: [(number: Int, title: String)] = []
    @State private var error: String?
    @State private var working = false

    private var project: Project? { projectID.flatMap { store.project($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("New Meeting").font(.title2.weight(.semibold))
                if projectGiven, let project {
                    Text("in \(project.name)").foregroundStyle(.secondary)
                }
                Spacer()
                if !projectGiven {
                    Picker("Project", selection: $projectID) {
                        ForEach(store.projects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            patternPicker
            Text(pattern.blurb)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if pattern == .review { prField }

            TextField(pattern.topicPrompt, text: $topic, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3...8)
                .padding(12)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                if pattern.seatRange.count > 1 {
                    GridRow {
                        Text("Agents")
                        Stepper("\(seats)", value: $seats, in: pattern.seatRange).fixedSize()
                    }
                }
                if pattern.usesRounds {
                    GridRow {
                        Text("Rounds")
                        Stepper("\(rounds)", value: $rounds, in: 1...4).fixedSize()
                            .help(pattern.roundsExplainer)
                    }
                }
                GridRow {
                    Text(splitModels ? "\(pattern.leadSeat)'s model" : "Model")
                    HStack(spacing: 12) {
                        Picker("Model", selection: $model) { modelOptions }
                            .labelsHidden().fixedSize()
                        Toggle("Different model for \(pattern.otherSeats.lowercased())", isOn: $splitModels.animation())
                            .toggleStyle(.checkbox)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if splitModels {
                    GridRow {
                        Text("\(pattern.otherSeats)' model")
                        Picker("Other seats' model", selection: $otherModel) { modelOptions }
                            .labelsHidden().fixedSize()
                    }
                }
            }

            Text("At the table: " + tableLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let project, !project.isGitRepo, pattern.changesCode {
                Text("\(project.name) isn't a git repository, so the agents work in its folder directly rather than on their own branch.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Starting…" : "Start Meeting") { start() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(working || projectID == nil)
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            let inferred = store.currentProjectID ?? (store.projects.count == 1 ? store.projects.first?.id : nil)
            projectGiven = inferred != nil
            projectID = inferred ?? store.projects.first?.id
            pattern = store.newMeetingPattern ?? .debate
            seats = MeetingDefaults.seats
            rounds = MeetingDefaults.rounds
            model = MeetingDefaults.model
            splitModels = MeetingDefaults.splitModels
            otherModel = MeetingDefaults.otherModel
        }
        .task(id: pattern == .review ? projectID : nil) { await loadPRs() }
    }

    /// Who's at the table, with each seat's model when they differ.
    private var tableLine: String {
        let names = pattern.seatNames(seats)
        guard splitModels, otherModel != model else { return names.joined(separator: ", ") }
        let label = { (m: String) in m == "default" ? "Default" : m.capitalized }
        return "\(names[0]) (\(label(model))), " + names.dropFirst().joined(separator: ", ") + " (\(label(otherModel)))"
    }

    private var patternPicker: some View {
        HStack(spacing: 6) {
            ForEach(MeetingPattern.allCases) { p in
                Button { pattern = p } label: {
                    VStack(spacing: 6) {
                        Image(systemName: p.symbol).font(.body).frame(height: 18)
                        Text(p.name).font(.caption).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .foregroundStyle(pattern == p ? .primary : .secondary)
                    .background(pattern == p ? Color.white.opacity(0.1) : Theme.surface,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(pattern == p ? Color.white.opacity(0.25) : Theme.hairline, lineWidth: 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.squish)
            }
        }
        .animation(Motion.press, value: pattern)
    }

    @ViewBuilder private var prField: some View {
        HStack(spacing: 10) {
            Text("Pull request")
            if openPRs.isEmpty {
                TextField("Number", text: $prNumber)
                    .frame(width: 90)
            } else {
                Picker("Pull request", selection: $prNumber) {
                    ForEach(openPRs, id: \.number) { pr in
                        Text("#\(pr.number) \(pr.title)").lineLimit(1).tag(String(pr.number))
                    }
                }
                .labelsHidden()
            }
        }
    }

    private func loadPRs() async {
        guard pattern == .review, let gh = store.tools.gh, let project, project.repo != nil || project.isGitRepo else { return }
        let r = await Shell.run(gh, ["pr", "list", "--json", "number,title", "--limit", "30"], cwd: project.path)
        guard r.ok, let list = try? JSONSerialization.jsonObject(with: Data(r.out.utf8)) as? [[String: Any]] else { return }
        openPRs = list.compactMap { item in
            guard let n = item["number"] as? Int else { return nil }
            return (n, item["title"] as? String ?? "")
        }
        if prNumber.isEmpty, let first = openPRs.first { prNumber = String(first.number) }
    }

    private func start() {
        guard let projectID else { return }
        working = true
        error = nil
        let pr = Int(prNumber.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        Task {
            do {
                try await store.startMeeting(projectID: projectID, pattern: pattern, topic: topic,
                                             seats: seats, rounds: pattern.usesRounds ? rounds : 1,
                                             prNumber: pattern == .review ? pr : nil, model: model,
                                             otherModel: splitModels ? otherModel : nil)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

// MARK: Meeting room

/// A meeting in progress, laid out like a project's workspace: a tab row (the table with every seat's live
/// terminal, one tab per seat, and the outcome once there is one) over whichever tab is open.
struct MeetingRoomView: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    @State private var askingToPost = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let note = meeting.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 4)
            }
            MeetingTabBar(meeting: meeting)
            Group {
                switch store.meetingTab {
                case .seat(let id) where store.agent(id) != nil:
                    seatView(store.agent(id)!)
                        .id(id)
                case .outcome:
                    OutcomeView(meeting: meeting)
                default:
                    table
                }
            }
            .transition(Motion.enter)
        }
        .animation(Motion.bouncy, value: store.meetingTab)
        .onAppear { store.refreshUsage(meeting.id) }
        .confirmationDialog("Post this review on pull request #\(meeting.prNumber ?? 0)?", isPresented: $askingToPost) {
            Button("Post Review") { Task { await store.postReview(meeting.id) } }
        } message: {
            Text("It's posted as a comment from your GitHub account, and everyone who can see the repository can read it.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { store.meetingSelection = nil } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("All meetings")
            Image(systemName: meeting.pattern.symbol).foregroundStyle(.secondary)
            Text(meeting.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .layoutPriority(1)
                .help(meeting.topic)
            Text(meetingProgress(meeting))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(details)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(meeting.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            TokenBadge(agents: meeting.seats.map(\.agentID), scope: "this meeting")
            HStack(spacing: 2) {
                Button { store.revealInFinder(meeting.notesURL.path) } label: { Image(systemName: "folder") }
                    .help("Show the meeting's notes in Finder")
                switch meeting.status {
                case .running:
                    Button { store.pauseMeeting(meeting.id) } label: { Image(systemName: "pause.fill") }
                        .help("Pause. Every seat stops; Resume carries on from this step.")
                case .paused:
                    Button { store.resumeMeeting(meeting.id) } label: { Image(systemName: "play.fill") }
                        .help("Resume from this step")
                case .finished:
                    Button { NSWorkspace.shared.open(meeting.outcomeURL) } label: { Image(systemName: "doc.text") }
                        .help("Open the outcome in your usual editor")
                        .disabled(!FileManager.default.fileExists(atPath: meeting.outcomeURL.path))
                    Button { store.revealFile(meeting.outcomeURL) } label: { Image(systemName: "magnifyingglass") }
                        .help("Show the outcome in Finder")
                        .disabled(!FileManager.default.fileExists(atPath: meeting.outcomeURL.path))
                    if meeting.pattern == .review, meeting.prNumber != nil {
                        Button { askingToPost = true } label: {
                            Image(systemName: meeting.posted ? "checkmark.bubble" : "text.bubble")
                        }
                        .help(meeting.posted ? "Posted on the pull request" : "Post the review on the pull request")
                        .disabled(meeting.posted || store.tools.gh == nil)
                    }
                }
            }
            .buttonStyle(.borderless)
            .imageScale(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .glassEffect(.regular.interactive(), in: .capsule)
            .animation(Motion.bouncy, value: meeting.status)
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 6)
    }

    /// Branch and commit, small. Tokens and cost are in the badge beside it.
    private var details: String {
        var parts: [String] = []
        if let branch = meeting.branch { parts.append(branch) }
        if let commit = meeting.commit { parts.append("committed \(commit)") }
        return parts.joined(separator: " · ")
    }

    private var table: some View {
        let ids = tableOrder
        return TileGrid(items: ids, pins: meeting.tablePins ?? [:],
                        onReorder: { order in store.updateMeeting(meeting.id) { $0.tableOrder = order } },
                        onPin: { pins in store.updateMeeting(meeting.id) { $0.tablePins = pins.isEmpty ? nil : pins } }) { id, isDragged, drag in
            if let agent = store.agent(id) {
                SeatTile(meeting: meeting, agent: agent, isDragged: isDragged, drag: drag)
            }
        }
    }

    /// Where you've put the seats on the table. Moving one doesn't change who chairs.
    private var tableOrder: [UUID] {
        let ids = meeting.seats.map(\.agentID)
        let saved = (meeting.tableOrder ?? []).filter(ids.contains)
        return saved + ids.filter { !saved.contains($0) }
    }

    @ViewBuilder private func seatView(_ agent: Agent) -> some View {
        if !agent.hasStarted && store.state(agent.id).status == .asleep {
            Text("\(agent.title) joins when it's their turn.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            AgentDetailView(agent: agent)
        }
    }
}

struct MeetingTabBar: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    @Namespace private var selection

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 4) {
                    WorkspaceTab(selected: store.meetingTab == .table, namespace: selection, help: "Every seat's terminal, side by side") {
                        Image(systemName: "rectangle.3.group")
                        Text("Table")
                    } action: {
                        store.meetingTab = .table
                    }
                    ForEach(meeting.seats, id: \.agentID) { seat in
                        WorkspaceTab(selected: store.meetingTab == .seat(seat.agentID), namespace: selection,
                                     help: store.state(seat.agentID).activity) {
                            StatusDot(status: store.state(seat.agentID).status, size: 7)
                            Text(seat.name)
                        } action: {
                            store.meetingTab = .seat(seat.agentID)
                        }
                    }
                    if meeting.status == .finished || FileManager.default.fileExists(atPath: meeting.outputURL.path) {
                        WorkspaceTab(selected: store.meetingTab == .outcome, namespace: selection, help: meeting.savedPath ?? meeting.outputPath) {
                            Image(systemName: "doc.text")
                            Text("Outcome")
                        } action: {
                            store.meetingTab = .outcome
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .scrollClipDisabled()
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// One seat on the table: its live terminal, which you can watch and type into, under a title bar that
/// says where it is with its turn.
struct SeatTile<Drag: Gesture>: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    let agent: Agent
    var isDragged = false
    let drag: Drag

    var body: some View {
        let s = store.state(agent.id)
        let turn = meeting.turns[agent.id]
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                StatusDot(status: s.status, size: 7)
                Text(agent.title).font(.callout.weight(.medium)).lineLimit(1).layoutPriority(1)
                Text(turnLabel(turn))
                    .font(.caption)
                    .foregroundStyle(turn == .stuck || s.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                if turn == .working || turn == .nudged {
                    Text(s.activity).font(.caption).foregroundStyle(.tertiary).lineLimit(1).shownInTiles(from: 480)
                }
                Spacer(minLength: 6)
                if turn == .stuck || turn == .nudged {
                    Button("Count as Done") { store.markTurnDone(agent.id) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Move on without waiting for its notes file")
                }
                TokenBadge(agents: [agent.id]).shownInTiles(from: 400)
                Button { store.meetingTab = .seat(agent.id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Open in its own tab")
            }
            .tileHeader(drag)

            AskBar(agentID: agent.id)
                .padding(.horizontal, 8)
                .padding(.bottom, s.ask != nil && s.status == .needsYou ? 6 : 0)

            Group {
                if s.status == .asleep || store.stopped.contains(agent.id) {
                    VStack(spacing: 10) {
                        Text(placeholder(s)).font(.callout).foregroundStyle(.secondary)
                        if meeting.status == .finished && agent.hasStarted {
                            Button("Continue the Chat") { store.start(agent.id) }
                                .buttonStyle(.glass)
                                .help("Starts its session again, so you can ask it follow-up questions")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TerminalHost(agent: agent, focus: false)
                        .id(store.terminalGeneration[agent.id, default: 0])
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
        }
        .tileChrome(isDragged: isDragged, highlight: s.status == .needsYou || turn == .stuck)
    }

    private func turnLabel(_ turn: TurnState?) -> String {
        switch turn {
        case .working: "Their turn"
        case .nudged: "Reminded to write its notes"
        case .stuck: "Stopped without writing its notes"
        case .done: "Turn done"
        case nil:
            switch meeting.status {
            case .running: "Waiting for their turn"
            case .paused: "Paused"
            case .finished: "Done"
            }
        }
    }

    private func placeholder(_ s: LiveState) -> String {
        if !agent.hasStarted { return meeting.status == .finished ? "Didn't take part" : "Joins when it's their turn" }
        return meeting.status == .finished ? "Meeting over" : (s.activity.isEmpty ? "Not running" : s.activity)
    }
}

/// The meeting's outcome document, read from disk.
struct OutcomeView: View {
    let meeting: Meeting
    /// Off where the view already sits on a card, like a Canvas tile.
    var framed = true
    @State private var text: String?

    var body: some View {
        let scroll = ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let text {
                    ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        MarkdownLine(line: line)
                    }
                    Divider().overlay(Theme.hairline).padding(.top, 16)
                    HStack(spacing: 8) {
                        Text(meeting.outcomeURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.outcomeURL]) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .help("Open the folder with the outcome selected")
                    }
                } else {
                    Text(meeting.status == .finished
                         ? "The outcome document isn't there. It may have been moved: \(meeting.savedPath ?? meeting.outputPath)"
                         : "The outcome shows here once the meeting has written it.")
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
            .padding(framed ? 28 : 16)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        Group {
            if framed {
                scroll
                    .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .padding([.horizontal, .bottom], 14)
            } else {
                scroll
            }
        }
        .task(id: meeting.status) {
            text = try? String(contentsOf: meeting.outcomeURL, encoding: .utf8)
        }
    }
}

/// One line of Markdown: headings, bullets and inline styling. Enough for a meeting's write-up.
struct MarkdownLine: View {
    let line: String

    var body: some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix { $0 == "#" }.count
            Text(inline(String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                .font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 10 : 4)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(trimmed.dropFirst(2))))
            }
            .padding(.leading, CGFloat(line.prefix { $0 == " " }.count) * 6)
        } else if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else {
            Text(inline(line))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}
