import SwiftUI

/// Tokens each Claude agent has used, and what they'd cost at Claude API prices.
/// - Tokens are counted from the agent's transcript, which Claude Code writes as it goes. The status line's
///   own token fields only describe the last request, so they can't be added up.
/// - The cost is Claude Code's own estimate, from the status line. It covers one run of the CLI, so when an
///   agent restarts and the number drops, what it had reached is kept in `baseCost`.
/// A subscription isn't billed per token, so its real cost per agent can't be worked out. The API price is
/// the comparison shown instead.
/// Nothing polls: each agent's status file is watched, and Claude Code rewrites it after every reply.
@MainActor @Observable
final class SpendModel {
    struct Entry: Codable, Equatable {
        /// What the running session has reported.
        var cost = 0.0
        /// What earlier runs reached.
        var baseCost = 0.0
        /// Every transcript the agent has written to. A resumed or cleared session can start a new one.
        var transcripts: [String] = []
        var totalCost: Double { baseCost + cost }
    }

    private(set) var entries: [UUID: Entry] = [:]
    private(set) var tokens: [UUID: TokenCount] = [:]
    /// When each agent used its tokens.
    private(set) var histories: [UUID: UsageHistory] = [:]
    /// What deleted agents used, so the Overview's history doesn't lose it.
    private(set) var archived = UsageHistory()

    /// Every agent's history, deleted ones included.
    var allHistory: UsageHistory { histories.values.reduce(archived, +) }

    /// Called with an agent's estimated cost before and after it changes.
    @ObservationIgnored var onCostChange: ((UUID, Double, Double) -> Void)?

    let file: URL
    private let archiveFile: URL
    private let statusFile: (UUID) -> URL
    @ObservationIgnored private var watches: [UUID: FileWatch] = [:]
    @ObservationIgnored private var readers: [UUID: TranscriptReader] = [:]
    @ObservationIgnored private var reading: Set<UUID> = []
    @ObservationIgnored private var readAgain: Set<UUID> = []

    init(file: URL, statusFile: @escaping (UUID) -> URL) {
        self.file = file
        self.statusFile = statusFile
        archiveFile = file.deletingLastPathComponent().appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: archiveFile),
           let saved = try? JSONDecoder().decode(UsageHistory.self, from: data) {
            archived = saved
        }
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([UUID: Entry].self, from: data) {
            entries = saved
        }
    }

    /// Starts following an agent. Safe to call again.
    func watch(_ id: UUID) {
        guard watches[id] == nil else { return }
        let url = statusFile(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data())
        }
        watches[id] = FileWatch(url: url) { [weak self] in self?.readStatus(id) }
        readStatus(id)
        countTokens(id)
    }

    /// Stops following an agent that's being deleted, so its status file can go.
    func forget(_ id: UUID) {
        watches[id] = nil
        readers[id] = nil
        tokens[id] = nil
        if let h = histories.removeValue(forKey: id), !h.isEmpty {
            archived = archived + h
            if let data = try? JSONEncoder().encode(archived) { try? data.write(to: archiveFile, options: .atomic) }
        }
        if entries.removeValue(forKey: id) != nil { save() }
    }

    func tokens(for ids: [UUID]) -> TokenCount { ids.reduce(TokenCount()) { $0 + (tokens[$1] ?? TokenCount()) } }
    func cost(for ids: [UUID]) -> Double { ids.reduce(0) { $0 + (entries[$1]?.totalCost ?? 0) } }

    private func readStatus(_ id: UUID) {
        // A half-written file doesn't parse; the write that finishes it brings another event.
        guard let data = try? Data(contentsOf: statusFile(id)), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var entry = entries[id] ?? Entry()
        if let cost = ((json["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue {
            if cost + 1e-9 < entry.cost { entry.baseCost += entry.cost }
            entry.cost = cost
        }
        if let path = json["transcript_path"] as? String, !path.isEmpty, !entry.transcripts.contains(path) {
            entry.transcripts.append(path)
        }
        if entry != entries[id] {
            let old = entries[id]?.totalCost ?? 0
            entries[id] = entry
            save()
            if entry.totalCost != old { onCostChange?(id, old, entry.totalCost) }
        }
        countTokens(id)
    }

    /// Reads whatever the transcripts gained since last time, off the main thread.
    private func countTokens(_ id: UUID) {
        guard let paths = entries[id]?.transcripts, !paths.isEmpty else { return }
        if reading.contains(id) {
            readAgain.insert(id)
            return
        }
        reading.insert(id)
        let start = readers[id] ?? TranscriptReader()
        Task { [weak self] in
            let reader = await Task.detached { var r = start; r.advance(paths); return r }.value
            guard let self else { return }
            reading.remove(id)
            // Deleted while reading.
            guard watches[id] != nil else { return }
            readers[id] = reader
            if tokens[id] != reader.count { tokens[id] = reader.count }
            if histories[id] != reader.history { histories[id] = reader.history }
            if readAgain.remove(id) != nil { countTokens(id) }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }
}

struct TokenCount: Equatable, Sendable {
    var input = 0
    var cacheWrite = 0
    var cacheRead = 0
    var output = 0
    var total: Int { input + cacheWrite + cacheRead + output }

    static func + (a: TokenCount, b: TokenCount) -> TokenCount {
        TokenCount(input: a.input + b.input, cacheWrite: a.cacheWrite + b.cacheWrite,
                   cacheRead: a.cacheRead + b.cacheRead, output: a.output + b.output)
    }
}

/// Adds up the token usage in Claude Code transcripts, reading each file only from where it left off.
/// One reply is written as several lines that repeat its usage, so each message is counted once by its id.
/// Subagents write their own transcripts in a folder next to the main one; those count too.
struct TranscriptReader: Sendable {
    private(set) var count = TokenCount()
    private(set) var history = UsageHistory()
    /// The 5-minute stretches that already had a reply, so busy time across subagents is counted once.
    private var slots: Set<Int> = []
    private var offsets: [String: UInt64] = [:]
    private var seen: Set<String> = []

    mutating func advance(_ transcripts: [String]) {
        for path in transcripts {
            read(path)
            let subagents = (path as NSString).deletingPathExtension + "/subagents"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: subagents)) ?? [] where name.hasSuffix(".jsonl") {
                read(subagents + "/" + name)
            }
        }
    }

    private mutating func read(_ path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        var offset = offsets[path] ?? 0
        let size = (try? handle.seekToEnd()) ?? 0
        // Rewritten from scratch: read it all again. Message ids keep anything from being counted twice.
        if size < offset { offset = 0 }
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(),
              let end = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        // Only whole lines; a line still being written is read next time.
        let complete = data[data.startIndex...end]
        offsets[path] = offset + UInt64(complete.count)
        let marker = Data(#""usage""#.utf8)
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in complete.split(separator: UInt8(ascii: "\n")) where line.range(of: marker) != nil {
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  json["type"] as? String == "assistant",
                  let message = json["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let key = message["id"] as? String ?? json["requestId"] as? String ?? json["uuid"] as? String ?? ""
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
            let t = TokenCount(input: n("input_tokens"), cacheWrite: n("cache_creation_input_tokens"),
                               cacheRead: n("cache_read_input_tokens"), output: n("output_tokens"))
            count = count + t
            if let stamp = json["timestamp"] as? String, let date = dates.date(from: stamp) {
                let fresh = slots.insert(Int(date.timeIntervalSince1970 / 300)).inserted
                history.add(t, model: message["model"] as? String, at: date, minutes: fresh ? 5 : 0)
            }
        }
    }
}

// MARK: Badge

/// Tokens used and the API-price estimate, small, in a header's top right. Shows nothing until there's
/// something to count, so Codex agents and browser tabs get no badge.
struct TokenBadge: View {
    @Environment(AppStore.self) private var store
    let agents: [UUID]
    /// Who the numbers belong to, for the tooltip: "this agent", "this meeting"…
    var scope = "this agent"

    var body: some View {
        let spend = store.spend
        let tokens = spend.tokens(for: agents)
        let cost = spend.cost(for: agents)
        if tokens.total > 0 || cost > 0 {
            HStack(spacing: 4) {
                Text("\(Self.short(tokens.total)) tokens")
                if cost > 0 {
                    Text("·").foregroundStyle(.quaternary)
                    Text("≈ \(Self.money(cost))")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .help(help(tokens, cost))
            .contentTransition(.numericText())
            .animation(Motion.press, value: tokens.total)
        }
    }

    private func help(_ t: TokenCount, _ cost: Double) -> String {
        let f = { (n: Int) in n.formatted(.number) }
        var s = "Tokens \(scope) has used: \(f(t.total)) in all. "
        s += "\(f(t.input)) new input, \(f(t.cacheRead)) read from the cache, \(f(t.cacheWrite)) written to the cache, \(f(t.output)) output."
        if cost > 0 {
            s += "\n\nAt Claude API prices this would cost about \(Self.money(cost)), using Claude Code's own estimate. "
            s += "Work done with an API key is billed about this much. A plan isn't charged per token, so for plan work it's only a comparison."
        }
        return s
    }

    static func short(_ n: Int) -> String {
        switch n {
        case ..<1_000: "\(n)"
        case ..<100_000: String(format: "%.1fk", Double(n) / 1_000).replacingOccurrences(of: ".0k", with: "k")
        case ..<1_000_000: "\(n / 1_000)k"
        default: String(format: "%.1fM", Double(n) / 1_000_000).replacingOccurrences(of: ".0M", with: "M")
        }
    }

    static func money(_ v: Double) -> String {
        v < 0.01 ? "<$0.01" : String(format: "$%.2f", v)
    }
}
