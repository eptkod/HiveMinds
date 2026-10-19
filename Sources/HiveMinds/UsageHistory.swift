import Foundation

/// When agents used their tokens, for the Overview's charts. Built from the timestamps in Claude Code
/// transcripts as they're read, so nothing extra is recorded while agents work.
struct UsageHistory: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        var tokens = 0
        var output = 0
        var replies = 0
        /// Minutes an agent was busy: every 5-minute stretch with at least one reply counts as 5.
        var minutes = 0

        static func + (a: Day, b: Day) -> Day {
            Day(tokens: a.tokens + b.tokens, output: a.output + b.output, replies: a.replies + b.replies, minutes: a.minutes + b.minutes)
        }
    }

    /// By the start of the day, in seconds since 1970.
    var days: [Int: Day] = [:]
    /// Tokens by hour of the day, 0 to 23.
    var hours = [Int](repeating: 0, count: 24)
    /// Tokens by model, in Claude Code's ids ("claude-opus-5-5").
    var models: [String: Int] = [:]

    var isEmpty: Bool { days.isEmpty }

    mutating func add(_ t: TokenCount, model: String?, at date: Date, minutes: Int) {
        let cal = Calendar.current
        let key = Self.key(date, cal)
        var day = days[key] ?? Day()
        day.tokens += t.total
        day.output += t.output
        day.replies += 1
        day.minutes += minutes
        days[key] = day
        hours[cal.component(.hour, from: date)] += t.total
        if let model, !model.hasPrefix("<") { models[model, default: 0] += t.total }
    }

    func day(_ date: Date) -> Day { days[Self.key(date, .current)] ?? Day() }

    static func key(_ date: Date, _ cal: Calendar = .current) -> Int {
        Int(cal.startOfDay(for: date).timeIntervalSince1970)
    }

    static func + (a: UsageHistory, b: UsageHistory) -> UsageHistory {
        var out = a
        out.days.merge(b.days, uniquingKeysWith: +)
        out.hours = zip(a.hours, b.hours).map(+)
        out.models.merge(b.models, uniquingKeysWith: +)
        return out
    }

    /// "claude-opus-5-5" → "Opus 5.5", "claude-haiku-4-5-20251001" → "Haiku 4.5".
    static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        parts.removeAll { $0.count == 8 && Int($0) != nil }
        guard let first = parts.first else { return id }
        let rest = parts.dropFirst().joined(separator: ".")
        return first.prefix(1).uppercased() + first.dropFirst() + (rest.isEmpty ? "" : " " + rest)
    }
}
