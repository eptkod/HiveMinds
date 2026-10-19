import SwiftUI
import AppKit

// MARK: Reading what the seats said

/// One thing a seat did in its Claude Code session, read from the session's transcript.
struct MeetingChatEntry: Identifiable, Sendable {
    enum Kind: Sendable {
        /// HiveMinds handed the seat its turn in this step.
        case turn(String)
        /// Something the seat said.
        case said(String)
        /// The seat wrote its notes (or the outcome): the file's name and what it wrote.
        case wrote(file: String, text: String, isOutcome: Bool)
        /// A tool call, in plain words.
        case action(String)
        /// HiveMinds reminded the seat to write its notes.
        case reminder
        /// Something you typed into the seat's terminal.
        case you(String)
    }
    let id: String
    let agentID: UUID
    let date: Date
    let kind: Kind
}

/// Where to find a seat's transcript.
struct SeatSource: Sendable {
    let agentID: UUID
    let sessionID: UUID
    let cwd: String
}

/// Reads the seats' Claude Code transcripts (`~/.claude/projects/<folder>/<session>.jsonl`). It remembers how
/// far it got in each file, so each refresh only reads what's new. Runs off the main thread.
actor MeetingTranscripts {
    private struct Source {
        var offset: UInt64 = 0
        var entries: [MeetingChatEntry] = []
    }
    private var sources: [URL: Source] = [:]
    private var found: [UUID: URL] = [:]

    func entries(for seats: [SeatSource], notesDir: String, outputPath: String) -> [MeetingChatEntry] {
        var all: [MeetingChatEntry] = []
        for seat in seats {
            guard let url = transcript(seat) else { continue }
            var source = sources[url] ?? Source()
            read(url, into: &source, seat: seat.agentID, notesDir: notesDir, outputPath: outputPath)
            sources[url] = source
            all += source.entries
        }
        return all.sorted { $0.date < $1.date }
    }

    private func transcript(_ seat: SeatSource) -> URL? {
        if let url = found[seat.sessionID] { return url }
        let base = Self.claudeProjectsDir
        let name = seat.sessionID.uuidString.lowercased() + ".jsonl"
        // Claude Code names the folder after the working directory, with everything but letters and digits as "-".
        let folder = String(seat.cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        var url: URL? = base.appendingPathComponent(folder).appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url!.path) {
            // Very long folder names are shortened, so look in every folder for the session.
            let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
            url = dirs.map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath: $0.path) }
        }
        if let url { found[seat.sessionID] = url }
        return url
    }

    private static var claudeProjectsDir: URL {
        let config = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude"
        return URL(fileURLWithPath: config).appendingPathComponent("projects")
    }

    private func read(_ url: URL, into source: inout Source, seat: UUID, notesDir: String, outputPath: String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < source.offset { source = Source() }
        guard size > source.offset else { return }
        try? handle.seek(toOffset: source.offset)
        guard let data = try? handle.readToEnd(), let end = data.lastIndex(of: 0x0A) else { return }
        // Only whole lines: a line still being written is read next time.
        source.offset += UInt64(end - data.startIndex + 1)
        for line in data[data.startIndex..<end].split(separator: 0x0A) {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            source.entries += Self.parse(json, seat: seat, notesDir: notesDir, outputPath: outputPath)
        }
    }

    private static func parse(_ json: [String: Any], seat: UUID, notesDir: String, outputPath: String) -> [MeetingChatEntry] {
        let type = json["type"] as? String
        guard type == "user" || type == "assistant",
              json["isMeta"] as? Bool != true, json["isSidechain"] as? Bool != true,
              json["isCompactSummary"] as? Bool != true,
              let message = json["message"] as? [String: Any] else { return [] }
        let date = (json["timestamp"] as? String).flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) } ?? .distantPast
        let lineID = json["uuid"] as? String ?? UUID().uuidString
        var out: [MeetingChatEntry] = []
        func add(_ kind: MeetingChatEntry.Kind) {
            out.append(MeetingChatEntry(id: "\(lineID)-\(out.count)", agentID: seat, date: date, kind: kind))
        }

        if type == "user" {
            var texts: [String] = []
            if let s = message["content"] as? String { texts = [s] }
            else if let blocks = message["content"] as? [[String: Any]] {
                texts = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            }
            for text in texts {
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty || t.hasPrefix("<") { continue }
                if t.hasPrefix("HiveMinds meeting, turn \""), let title = t.dropFirst(25).split(separator: "\"").first {
                    add(.turn(String(title)))
                } else if t.hasPrefix("You stopped before writing") {
                    add(.reminder)
                } else {
                    add(.you(t))
                }
            }
            return out
        }

        for block in message["content"] as? [[String: Any]] ?? [] {
            switch block["type"] as? String {
            case "text":
                let t = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { add(.said(t)) }
            case "tool_use":
                let name = block["name"] as? String ?? "a tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let path = input["file_path"] as? String ?? ""
                if name == "Write", path.hasPrefix(notesDir) || path == outputPath {
                    add(.wrote(file: (path as NSString).lastPathComponent, text: input["content"] as? String ?? "",
                               isOutcome: path == outputPath))
                } else {
                    add(.action(describeToolUse(name, input)))
                }
            default:
                break
            }
        }
        return out
    }
}

// MARK: The chat

/// A row in the chat: entries grouped so a run of tool calls reads as one line.
private struct FeedRow: Identifiable {
    enum Kind {
        case step(String)
        case said(String)
        case wrote(file: String, text: String, isOutcome: Bool)
        case actions([String])
        case reminder
        case you(String)
    }
    let id: String
    let agentID: UUID
    let date: Date
    let kind: Kind
    /// The seat's name and badge show on the first of its rows in a run.
    var showsHeader = true
}

private func feedRows(_ entries: [MeetingChatEntry]) -> [FeedRow] {
    var rows: [FeedRow] = []
    var stepsShown: Set<String> = []
    for e in entries {
        switch e.kind {
        case .turn(let title):
            // Every seat in a step gets the same turn, so the step shows once.
            if stepsShown.insert(title).inserted { rows.append(FeedRow(id: e.id, agentID: e.agentID, date: e.date, kind: .step(title))) }
            continue
        case .action(let text):
            if let last = rows.last, last.agentID == e.agentID, case .actions(let list) = last.kind {
                rows[rows.count - 1] = FeedRow(id: last.id, agentID: last.agentID, date: last.date,
                                               kind: .actions(list + [text]), showsHeader: last.showsHeader)
                continue
            }
            rows.append(FeedRow(id: e.id, agentID: e.agentID, date: e.date, kind: .actions([text])))
        case .said(let text): rows.append(FeedRow(id: e.id, agentID: e.agentID, date: e.date, kind: .said(text)))
        case .wrote(let file, let text, let isOutcome):
            rows.append(FeedRow(id: e.id, agentID: e.agentID, date: e.date, kind: .wrote(file: file, text: text, isOutcome: isOutcome)))
        case .reminder: rows.append(FeedRow(id: e.id, agentID: e.agentID, date: e.date, kind: .reminder))
        case .you(let text): rows.append(FeedRow(id: e.id, agentID: e.agentID, date: e.date, kind: .you(text)))
        }
        if rows.count > 1 {
            let prev = rows[rows.count - 2]
            if case .step = prev.kind {} else if prev.agentID == e.agentID { rows[rows.count - 1].showsHeader = false }
        }
    }
    return rows
}

/// A seat's colour in the chat, by where it sits. Orange is left out: it means "needs you".
func seatColor(_ index: Int) -> Color {
    [Color.teal, .indigo, .pink, .mint, .yellow][index % 5]
}

/// The meeting as a chat: what each seat says and writes in its Claude Code session, turn by turn,
/// with who's working right now at the bottom. It reloads when a seat's hooks report something, never on a timer.
struct MeetingFeed: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    /// Tighter spacing, for a Canvas tile.
    var compact = false
    @State private var transcripts = MeetingTranscripts()
    @State private var entries: [MeetingChatEntry] = []
    @State private var loaded = false

    private struct RefreshKey: Hashable {
        let step: Int
        let status: MeetingStatus
        let updates: [Date]
    }

    var body: some View {
        let rows = feedRows(entries)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: compact ? 8 : 12) {
                    if loaded && rows.isEmpty {
                        Text(meeting.status == .finished ? "Nothing was said in this meeting." : "Nothing said yet. Each seat joins when it's their turn.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 24)
                    }
                    ForEach(rows) { row in
                        FeedRowView(row: row, meeting: meeting, compact: compact)
                            .id(row.id)
                    }
                    LiveFooter(meeting: meeting)
                        .id("live")
                }
                .padding(.horizontal, compact ? 12 : 20)
                .padding(.vertical, compact ? 10 : 16)
                .frame(maxWidth: compact ? .infinity : 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: rows.count) { _, _ in
                withAnimation(Motion.bouncy) { proxy.scrollTo("live", anchor: .bottom) }
            }
        }
        .task(id: refreshKey) {
            // Hooks often fire in bursts; wait for the burst to end before reading.
            if loaded { try? await Task.sleep(for: .milliseconds(300)) }
            guard !Task.isCancelled else { return }
            let seats = store.seatAgents(meeting).filter(\.hasStarted).map { SeatSource(agentID: $0.id, sessionID: $0.sessionID, cwd: $0.cwd) }
            let found = await transcripts.entries(for: seats, notesDir: meeting.absolute(meeting.notesDir),
                                                  outputPath: meeting.absolute(meeting.outputPath))
            guard !Task.isCancelled else { return }
            entries = found
            loaded = true
        }
    }

    private var refreshKey: RefreshKey {
        RefreshKey(step: meeting.step, status: meeting.status,
                   updates: meeting.seats.map { store.state($0.agentID).updated })
    }
}

private struct FeedRowView: View {
    @Environment(AppStore.self) private var store
    let row: FeedRow
    let meeting: Meeting
    let compact: Bool
    @State private var expanded = false

    var body: some View {
        switch row.kind {
        case .step(let title):
            HStack(spacing: 10) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).fixedSize()
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
            .padding(.vertical, compact ? 2 : 6)
        case .reminder:
            Text("HiveMinds reminded \(seatName) to write its notes")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, badgeSize + 10)
        default:
            HStack(alignment: .top, spacing: 10) {
                if row.showsHeader { SeatBadge(name: seatName, color: color, size: badgeSize) }
                else { Color.clear.frame(width: badgeSize, height: 1) }
                VStack(alignment: .leading, spacing: 4) {
                    if row.showsHeader {
                        HStack(spacing: 6) {
                            Text(isYou ? "You → \(seatName)" : seatName).font(.caption.weight(.semibold)).foregroundStyle(isYou ? .primary : color)
                            Text(row.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch row.kind {
        case .said(let text), .you(let text):
            Text(inline(text))
                .font(compact ? .callout : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .actions(let list):
            Text(list.count > 1 ? "\(list.last!) · \(list.count - 1) step\(list.count == 2 ? "" : "s") before" : list[0])
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help(list.joined(separator: "\n"))
        case .wrote(let file, let text, let isOutcome):
            note(file: file, text: text, isOutcome: isOutcome)
        default:
            EmptyView()
        }
    }

    private func note(file: String, text: String, isOutcome: Bool) -> some View {
        let lines = text.components(separatedBy: "\n")
        let limit = compact ? 6 : 14
        let shown = expanded ? lines : Array(lines.prefix(limit))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: isOutcome ? "checkmark.seal" : "doc.text").foregroundStyle(.secondary)
                Text(isOutcome ? "Wrote the outcome" : "Wrote \(file)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, line in MarkdownLine(line: line) }
            }
            .font(compact ? .callout : .body)
            .textSelection(.enabled)
            if lines.count > limit {
                Button(expanded ? "Show less" : "Show all \(lines.count) lines") {
                    withAnimation(Motion.bouncy) { expanded.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(compact ? 10 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(isOutcome ? Color.green.opacity(0.35) : Theme.hairline, lineWidth: 0.5))
    }

    private var isYou: Bool { if case .you = row.kind { true } else { false } }
    private var seatIndex: Int { meeting.seatIndex(row.agentID) ?? 0 }
    private var seatName: String { meeting.seats.first { $0.agentID == row.agentID }?.name ?? "A seat" }
    private var color: Color { seatColor(seatIndex) }
    private var badgeSize: CGFloat { compact ? 20 : 26 }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A seat's initial in a circle of its colour.
struct SeatBadge: View {
    let name: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.18), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
    }
}

/// Who's on their turn right now, and what they're doing. Nothing animates: it changes when their hooks do.
private struct LiveFooter: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch meeting.status {
            case .paused:
                HStack(spacing: 10) {
                    Text("Paused").font(.caption).foregroundStyle(.secondary)
                    Button("Resume") { store.resumeMeeting(meeting.id) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            case .finished:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    Text("Meeting over\(meeting.finishedAt.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .running:
                ForEach(meeting.seats, id: \.agentID) { seat in
                    if let turn = meeting.turns[seat.agentID], turn != .done {
                        let s = store.state(seat.agentID)
                        HStack(spacing: 8) {
                            StatusDot(status: s.status, size: 6)
                            Text(seat.name).font(.caption.weight(.medium)).foregroundStyle(seatColor(meeting.seatIndex(seat.agentID) ?? 0))
                            Text(turn == .stuck ? "Stopped without writing its notes" : (s.activity.isEmpty ? "Working…" : s.activity + "…"))
                                .font(.caption)
                                .foregroundStyle(turn == .stuck || s.status == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                                .lineLimit(1)
                            if turn == .stuck || s.status == .needsYou {
                                Button("Open") { store.openMeeting(meeting.id, tab: .seat(seat.agentID)) }
                                    .buttonStyle(.borderless).font(.caption)
                                    .help("Open its terminal to answer it")
                            }
                            if turn == .stuck {
                                Button("Count as Done") { store.markTurnDone(seat.agentID) }
                                    .buttonStyle(.borderless).font(.caption)
                                    .help("Move on without waiting for its notes file")
                            }
                        }
                    }
                }
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Overview

/// The meeting's steps as a thin bar: done, current and still to come.
struct StepStrip: View {
    let meeting: Meeting

    var body: some View {
        let steps = meeting.plan()
        HStack(spacing: 3) {
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                Capsule()
                    .fill(color(i))
                    .frame(height: 3)
                    .help(step.title)
            }
        }
        .animation(Motion.bouncy, value: meeting.step)
    }

    private func color(_ i: Int) -> Color {
        if meeting.status == .finished || i < meeting.step { return .white.opacity(0.55) }
        if i == meeting.step { return meeting.status == .running ? .blue : .white.opacity(0.3) }
        return .white.opacity(0.1)
    }
}

/// What a meeting overview shows: the chat while it runs, and the outcome once it's finished
/// (with the chat a click away).
private struct MeetingOverviewBody: View {
    let meeting: Meeting
    let compact: Bool
    @State private var showChat = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                StepStrip(meeting: meeting)
                if meeting.status == .finished {
                    Picker("Show", selection: $showChat) {
                        Text("Outcome").tag(false)
                        Text("Chat").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .padding(.horizontal, compact ? 12 : 20)
            .padding(.vertical, compact ? 4 : 8)

            Group {
                if meeting.status == .finished && !showChat {
                    OutcomeView(meeting: meeting, framed: false)
                } else {
                    MeetingFeed(meeting: meeting, compact: compact)
                }
            }
            .transition(Motion.enter)
        }
        .animation(Motion.bouncy, value: showChat)
        .animation(Motion.bouncy, value: meeting.status)
    }
}

/// A meeting on its project's Canvas.
struct MeetingTile<Drag: Gesture>: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting
    var isDragged = false
    let drag: Drag

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: meeting.pattern.symbol).font(.caption).foregroundStyle(.secondary)
                Text(meeting.title).font(.callout.weight(.medium)).lineLimit(1)
                Text(meetingProgress(meeting))
                    .font(.caption)
                    .foregroundStyle(needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
                Spacer(minLength: 6)
                TokenBadge(agents: meeting.seats.map(\.agentID), scope: "this meeting")
                Button { store.openMeeting(meeting.id) } label: { Image(systemName: "rectangle.3.group") }
                    .buttonStyle(.borderless)
                    .help("Open the meeting room, with every seat's terminal")
                Button { store.selection = .meeting(meeting.id) } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .help("Open in its own tab")
                DeleteTileButton(title: "Take this meeting off the Canvas?",
                                 message: "Nothing stops or gets deleted. It stays on the Meetings page.",
                                 confirm: "Take Off", destructive: false) {
                    store.hideMeetingFromCanvas(meeting.id)
                }
            }
            .tileHeader(drag)

            MeetingOverviewBody(meeting: meeting, compact: true)
                .padding(.bottom, 4)
        }
        .tileChrome(isDragged: isDragged, highlight: needsYou)
        .contextMenu {
            Button("Open Meeting Room") { store.openMeeting(meeting.id) }
            if meeting.status == .running {
                Button("Pause") { store.pauseMeeting(meeting.id) }
            } else if meeting.status == .paused {
                Button("Resume") { store.resumeMeeting(meeting.id) }
            }
            Divider()
            Button("Take Off the Canvas") { store.hideMeetingFromCanvas(meeting.id) }
        }
    }

    private var needsYou: Bool {
        meeting.seats.contains { store.state($0.agentID).status == .needsYou || meeting.turns[$0.agentID] == .stuck }
    }
}

/// A meeting's overview as its own tab in the project's workspace.
struct MeetingOverviewPage: View {
    @Environment(AppStore.self) private var store
    let meeting: Meeting

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: meeting.pattern.symbol).foregroundStyle(.secondary)
                Text(meeting.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .help(meeting.topic)
                Text(meetingProgress(meeting)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    ForEach(meeting.seats, id: \.agentID) { seat in
                        SeatBadge(name: seat.name, color: seatColor(meeting.seatIndex(seat.agentID) ?? 0), size: 18)
                            .overlay(alignment: .bottomTrailing) {
                                StatusDot(status: store.state(seat.agentID).status, size: 6)
                            }
                            .help("\(seat.name): \(store.state(seat.agentID).activity)")
                    }
                }
                Spacer(minLength: 12)
                TokenBadge(agents: meeting.seats.map(\.agentID), scope: "this meeting")
                HStack(spacing: 2) {
                    Button { store.openMeeting(meeting.id) } label: { Image(systemName: "rectangle.3.group") }
                        .help("Open the meeting room, with every seat's terminal")
                    switch meeting.status {
                    case .running:
                        Button { store.pauseMeeting(meeting.id) } label: { Image(systemName: "pause.fill") }
                            .help("Pause. Every seat stops; Resume carries on from this step.")
                    case .paused:
                        Button { store.resumeMeeting(meeting.id) } label: { Image(systemName: "play.fill") }
                            .help("Resume from this step")
                    case .finished:
                        Button { NSWorkspace.shared.open(meeting.outputURL) } label: { Image(systemName: "doc.text") }
                            .help("Open the outcome in your usual editor")
                            .disabled(!FileManager.default.fileExists(atPath: meeting.outputURL.path))
                    }
                }
                .buttonStyle(.borderless)
                .imageScale(.small)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .glassEffect(.regular.interactive(), in: .capsule)
                .animation(Motion.bouncy, value: meeting.status)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 6)

            MeetingOverviewBody(meeting: meeting, compact: false)
                .tileChrome(isDragged: false, highlight: false)
                .padding([.horizontal, .bottom], 14)
        }
        .onAppear { store.refreshUsage(meeting.id) }
    }
}
