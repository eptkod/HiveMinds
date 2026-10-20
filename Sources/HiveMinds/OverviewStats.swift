import SwiftUI
import Charts

/// The honey accent from the brand palette (#F5B53D). One lit thing per chart.
private let honey = Color(red: 0.961, green: 0.710, blue: 0.239)
/// Bars that aren't lit.
private let bar = Color.white.opacity(0.32)

/// What the activity charts measure.
enum StatMetric: String, CaseIterable, Identifiable {
    case tokens = "Tokens", hours = "Hours"
    var id: String { rawValue }

    func value(_ d: UsageHistory.Day) -> Double {
        self == .tokens ? Double(d.tokens) : Double(d.minutes) / 60
    }

    func text(_ v: Double) -> String {
        switch self {
        case .tokens: "\(TokenBadge.short(Int(v))) tokens"
        case .hours: Self.hours(v)
        }
    }

    static func hours(_ h: Double) -> String {
        h == 0 ? "0 h" : h < 1 ? "\(Int((h * 60).rounded())) min" : String(format: h < 10 ? "%.1f h" : "%.0f h", h)
    }
}

/// Charts and numbers about how much the agents have done, at the top of the Overview.
struct OverviewStats: View {
    @Environment(AppStore.self) private var store
    @AppStorage(SettingKey.overviewMetric) private var metric = StatMetric.tokens
    @State private var wide = true

    var body: some View {
        let history = store.spend.allHistory
        let days = DaySeries(history)
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                StatTile(label: "Tokens", value: TokenBadge.short(days.totalTokens),
                         detail: "\(TokenBadge.short(days.today.tokens)) today")
                StatTile(label: "Agent hours", value: StatMetric.hours(days.totalHours),
                         detail: "\(StatMetric.hours(days.weekHours)) this week")
                StatTile(label: "Replies", value: days.totalReplies.formatted(.number.notation(.compactName)),
                         detail: "\(days.today.replies) today")
                StatTile(label: "Streak", value: days.streak == 1 ? "1 day" : "\(days.streak) days",
                         detail: "Best \(days.bestStreak)", lit: days.streak > 0 && days.streak == days.bestStreak)
            }

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Activity").font(.headline)
                        Spacer()
                        Picker("Measure", selection: $metric) {
                            ForEach(StatMetric.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    ActivityGrid(days: days, metric: metric)
                    Highlights(days: days, history: history)
                }
            }

            row {
                Card { RecentDays(days: days, metric: metric).frame(maxHeight: .infinity, alignment: .top) }
                Card { TimeOfDay(hours: history.hours).frame(maxHeight: .infinity, alignment: .top) }
            }

            row {
                Card { TokenMix().frame(maxHeight: .infinity, alignment: .top) }
                Card {
                    HStack(alignment: .top, spacing: 28) {
                        BarList(title: "By project", rows: projectRows)
                        BarList(title: "By model", rows: history.models
                            .map { (UsageHistory.modelName($0.key), $0.value) }
                            .sorted { $0.1 > $1.1 })
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 780 } action: { wide = $0 }
    }

    /// Two cards side by side with matching heights, or stacked when the window is narrow.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 14)) : AnyLayout(VStackLayout(spacing: 14))
        return layout { content() }.fixedSize(horizontal: false, vertical: true)
    }

    /// Live and deleted agents together, so removing a project, or adding it again, doesn't change the totals.
    private var projectRows: [(String, Int)] {
        let spend = store.spend
        var by: [String: Int] = [:]
        for p in store.projects {
            by[p.name, default: 0] += spend.tokens(for: store.agents.filter { $0.projectID == p.id }.map(\.id)).total
                + spend.removed(in: p).tokens.total
        }
        for r in spend.removed where !store.projects.contains(where: r.isFor) { by[r.name, default: 0] += r.tokens.total }
        return by.filter { $0.value > 0 }.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
}

// MARK: Days

/// The history as a run of calendar days, with the totals the Overview shows.
struct DaySeries {
    let history: UsageHistory
    let cal = Calendar.current
    let today: UsageHistory.Day
    let totalTokens: Int
    let totalReplies: Int
    let totalHours: Double
    let weekHours: Double
    let streak: Int
    let bestStreak: Int

    init(_ history: UsageHistory) {
        self.history = history
        let now = Date()
        today = history.day(now)
        totalTokens = history.days.values.reduce(0) { $0 + $1.tokens }
        totalReplies = history.days.values.reduce(0) { $0 + $1.replies }
        totalHours = Double(history.days.values.reduce(0) { $0 + $1.minutes }) / 60
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)?.start ?? now
        weekHours = Double(history.days.filter { $0.key >= Int(weekStart.timeIntervalSince1970) }.values.reduce(0) { $0 + $1.minutes }) / 60

        // The current streak can end yesterday: today isn't over yet.
        let active = Set(history.days.filter { $0.value.tokens > 0 }.keys)
        var run = 0
        var day = cal.startOfDay(for: now)
        if !active.contains(UsageHistory.key(day, cal)) { day = cal.date(byAdding: .day, value: -1, to: day)! }
        while active.contains(UsageHistory.key(day, cal)) {
            run += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        streak = run

        var best = 0, current = 0
        var previous: Date?
        for key in active.sorted() {
            let d = Date(timeIntervalSince1970: TimeInterval(key))
            if let previous, cal.dateComponents([.day], from: previous, to: d).day == 1 { current += 1 } else { current = 1 }
            best = max(best, current)
            previous = d
        }
        bestStreak = best
    }

    func day(_ date: Date) -> UsageHistory.Day { history.day(date) }

    /// The last `count` days, oldest first, ending today.
    func last(_ count: Int) -> [Date] {
        let today = cal.startOfDay(for: Date())
        return (0..<count).reversed().map { cal.date(byAdding: .day, value: -$0, to: today)! }
    }

    var busiest: (Date, UsageHistory.Day)? {
        history.days.max { $0.value.tokens < $1.value.tokens }.map { (Date(timeIntervalSince1970: TimeInterval($0.key)), $0.value) }
    }
}

// MARK: Tiles

private struct StatTile: View {
    let label: String
    let value: String
    let detail: String
    var lit = false

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(Motion.press, value: value)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 5) {
                    if lit { Image(systemName: "flame.fill").foregroundStyle(honey) }
                    Text(detail)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: Activity grid

/// A year of days, a column per week, like GitHub's contributions graph.
private struct ActivityGrid: View {
    let days: DaySeries
    let metric: StatMetric
    @State private var hovered: Date?
    @State private var width: CGFloat = 800

    private let gap: CGFloat = 3
    private let labelWidth: CGFloat = 28

    /// Up to a year of weeks, fewer when the card is narrow, with squares filling the width.
    private var weeks: Int { min(53, max(8, Int((width - labelWidth + gap) / (10 + gap)))) }
    private var cell: CGFloat { min(18, (width - labelWidth - CGFloat(weeks - 1) * gap) / CGFloat(weeks)) }

    var body: some View {
        let columns = self.columns
        let values = columns.flatMap { $0 }.compactMap { $0 }.map { metric.value(days.day($0)) }
        let steps = Self.steps(values)
        VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 0) {
                    weekdayLabels
                    VStack(alignment: .leading, spacing: 4) {
                        monthLabels(columns)
                        HStack(alignment: .top, spacing: gap) {
                            ForEach(columns.indices, id: \.self) { i in
                                VStack(spacing: gap) {
                                    ForEach(0..<7, id: \.self) { row in
                                        if let date = columns[i][row] {
                                            square(date, level: Self.level(metric.value(days.day(date)), steps))
                                        } else {
                                            Color.clear.frame(width: cell, height: cell)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }

            HStack(spacing: 4) {
                Text(caption(values))
                    .foregroundStyle(hovered == nil ? .tertiary : .secondary)
                    .contentTransition(.opacity)
                Spacer()
                Text("Less").foregroundStyle(.tertiary)
                ForEach(0..<5, id: \.self) { RoundedRectangle(cornerRadius: 2.5).fill(Self.color($0)).frame(width: cell, height: cell) }
                Text("More").foregroundStyle(.tertiary)
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func square(_ date: Date, level: Int) -> some View {
        let isHovered = hovered.map { days.cal.isDate($0, inSameDayAs: date) } ?? false
        return RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Self.color(level))
            .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(.white.opacity(isHovered ? 0.8 : 0), lineWidth: 1))
            .frame(width: cell, height: cell)
            .contentShape(Rectangle().inset(by: -gap / 2))
            .onHover { inside in
                if inside { hovered = date } else if isHovered { hovered = nil }
            }
    }

    private func caption(_ values: [Double]) -> String {
        if let hovered {
            let d = days.day(hovered)
            let when = hovered.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
            return d.replies == 0 ? "\(when) · nothing" : "\(when) · \(TokenBadge.short(d.tokens)) tokens · \(StatMetric.hours(Double(d.minutes) / 60)) · \(d.replies) replies"
        }
        return "\(metric.text(values.reduce(0, +))) in the last \(weeks >= 52 ? "year" : "\(weeks) weeks")"
    }

    /// Week columns, Sunday-first or Monday-first as the calendar has it; nil for days still to come.
    private var columns: [[Date?]] {
        let cal = days.cal
        let today = cal.startOfDay(for: Date())
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: today)!.start
        let first = cal.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)!
        return (0..<weeks).map { w in
            (0..<7).map { d in
                let date = cal.date(byAdding: .day, value: w * 7 + d, to: first)!
                return date > today ? nil : date
            }
        }
    }

    private var weekdayLabels: some View {
        let symbols = days.cal.shortWeekdaySymbols
        let firstWeekday = days.cal.firstWeekday - 1
        return VStack(alignment: .trailing, spacing: gap) {
            Text(" ").font(.caption2).frame(height: 13)
            ForEach(0..<7, id: \.self) { row in
                Text(row % 2 == 1 ? symbols[(row + firstWeekday) % 7] : "")
                    .font(.system(size: 9))
                    .fixedSize()
                    .foregroundStyle(.tertiary)
                    .frame(height: cell)
            }
        }
        .frame(width: labelWidth - 6, alignment: .trailing)
        .padding(.trailing, 6)
    }

    private func monthLabels(_ columns: [[Date?]]) -> some View {
        HStack(spacing: gap) {
            ForEach(columns.indices, id: \.self) { i in
                let start = columns[i].compactMap { $0 }.first
                let showsMonth = start.map { s in
                    i == 0 ? days.cal.component(.day, from: s) <= 7 : days.cal.component(.month, from: s) != columns[i - 1].compactMap { $0 }.first.map { days.cal.component(.month, from: $0) }
                } ?? false
                Color.clear
                    .frame(width: cell, height: 13)
                    .overlay(alignment: .leading) {
                        if showsMonth, let start {
                            Text(start.formatted(.dateTime.month(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
            }
        }
    }

    /// Where levels 2, 3 and 4 start: the quartiles of the days that had anything.
    private static func steps(_ values: [Double]) -> [Double] {
        let busy = values.filter { $0 > 0 }.sorted()
        guard !busy.isEmpty else { return [] }
        return [0.25, 0.5, 0.75].map { busy[min(busy.count - 1, Int(Double(busy.count) * $0))] }
    }

    private static func level(_ v: Double, _ steps: [Double]) -> Int {
        guard v > 0 else { return 0 }
        return min(4, 1 + steps.filter { v >= $0 }.count)
    }

    static func color(_ level: Int) -> Color {
        switch level {
        case 0: Color.white.opacity(0.06)
        case 1: honey.opacity(0.28)
        case 2: honey.opacity(0.5)
        case 3: honey.opacity(0.75)
        default: honey
        }
    }
}

// MARK: Highlights

private struct Highlights: View {
    let days: DaySeries
    let history: UsageHistory

    var body: some View {
        let peakHour = history.hours.indices.max { history.hours[$0] < history.hours[$1] }
        HStack(spacing: 18) {
            if let (date, day) = days.busiest, day.tokens > 0 {
                fact("trophy", "Busiest day", "\(date.formatted(.dateTime.month(.abbreviated).day())) · \(TokenBadge.short(day.tokens))")
            }
            if let peakHour, history.hours[peakHour] > 0 {
                fact("clock", "Peak hour", hourName(peakHour))
            }
            let output = history.days.values.reduce(0) { $0 + $1.output }
            if output > 0 {
                // About 0.75 words per token and 300 words on a printed page.
                fact("book.closed", "Written", "≈ \(max(1, Int(Double(output) * 0.75 / 300)).formatted()) pages")
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func fact(_ icon: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.tertiary)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .lineLimit(1)
    }
}

private func hourName(_ h: Int) -> String {
    Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())!.formatted(.dateTime.hour())
}

// MARK: Charts

/// The last 30 days as bars. Hover a bar to read it.
private struct RecentDays: View {
    let days: DaySeries
    let metric: StatMetric
    @State private var selected: Date?

    var body: some View {
        let dates = days.last(30)
        let values = dates.map { metric.value(days.day($0)) }
        let pick = selected.flatMap { s in dates.first { days.cal.isDate($0, inSameDayAs: s) } }
        VStack(alignment: .leading, spacing: 12) {
            ChartHeader(title: "Last 30 days",
                        value: pick.map { "\($0.formatted(.dateTime.month(.abbreviated).day())) · \(metric.text(metric.value(days.day($0))))" }
                            ?? "\(metric.text(values.reduce(0, +))) in all")
            Chart {
                ForEach(Array(zip(dates, values)), id: \.0) { date, v in
                    BarMark(x: .value("Day", date, unit: .day), y: .value(metric.rawValue, v))
                        .foregroundStyle(pick.map { days.cal.isDate($0, inSameDayAs: date) } ?? days.cal.isDateInToday(date) ? honey : bar)
                        .cornerRadius(3)
                }
            }
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: [3, 10, 17, 24].map { dates[$0] }) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(axisText(d)) } }
                }
            }
            .frame(height: 150)
        }
    }

    private func axisText(_ v: Double) -> String {
        metric == .tokens ? TokenBadge.short(Int(v)) : String(format: "%g h", v)
    }
}

/// Tokens by hour of the day, across all days.
private struct TimeOfDay: View {
    let hours: [Int]
    @State private var selected: Int?

    var body: some View {
        let peak = hours.indices.max { hours[$0] < hours[$1] } ?? 0
        let pick = selected.map { min(23, max(0, $0)) }
        VStack(alignment: .leading, spacing: 12) {
            ChartHeader(title: "When agents work",
                        value: pick.map { "\(hourName($0)) · \(TokenBadge.short(hours[$0])) tokens" } ?? "Peak at \(hourName(peak))")
            Chart {
                ForEach(0..<24, id: \.self) { h in
                    BarMark(x: .value("Hour", h), y: .value("Tokens", hours[h]))
                        .foregroundStyle(h == (pick ?? peak) && hours[h] > 0 ? honey : bar)
                        .cornerRadius(3)
                }
            }
            .chartXScale(domain: -0.5...23.5)
            .chartXSelection(value: $selected)
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { v in
                    AxisValueLabel { if let h = v.as(Int.self) { Text(hourName(h)) } }
                }
            }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.hairline)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(TokenBadge.short(Int(d))) } }
                }
            }
            .frame(height: 150)
        }
    }
}

private struct ChartHeader: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: Breakdowns

/// What the tokens were: mostly re-reading the cache, which is cheap, with a little new writing.
private struct TokenMix: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let t = store.spend.tokens(for: store.agents.map(\.id)) + store.spend.removedTokens
        let parts: [(String, Int, Color)] = [
            ("Read from cache", t.cacheRead, .white.opacity(0.32)),
            ("Written to cache", t.cacheWrite, .white.opacity(0.55)),
            ("New input", t.input, .white.opacity(0.8)),
            ("Output", t.output, honey),
        ]
        VStack(alignment: .leading, spacing: 14) {
            ChartHeader(title: "Token mix", value: "\(TokenBadge.short(t.total)) in all")
            GeometryReader { geo in
                let shown = parts.filter { $0.1 > 0 }
                let room = geo.size.width - CGFloat(max(0, shown.count - 1)) * 2
                // Tiny slices still show as a sliver; the biggest gives up the room they take.
                var widths = shown.map { max(3, room * CGFloat($0.1) / CGFloat(max(1, t.total))) }
                if let big = widths.indices.max(by: { widths[$0] < widths[$1] }) {
                    widths[big] -= widths.reduce(0, +) - room
                }
                return HStack(spacing: 2) {
                    ForEach(shown.indices, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(shown[i].2)
                            .frame(width: max(3, widths[i]))
                    }
                }
            }
            .frame(height: 10)
            VStack(spacing: 7) {
                ForEach(parts, id: \.0) { name, n, color in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
                        Text(name).foregroundStyle(.secondary)
                        Spacer()
                        Text(TokenBadge.short(n)).monospacedDigit()
                        Text(t.total > 0 ? "\(Int((Double(n) / Double(t.total) * 100).rounded()))%" : "–")
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

/// A short ranked list with a bar under each name. The top row is lit.
private struct BarList: View {
    let title: String
    let rows: [(String, Int)]

    var body: some View {
        let top = rows.prefix(5)
        let most = max(1, top.first?.1 ?? 1)
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if top.isEmpty {
                Text("Nothing yet").font(.caption).foregroundStyle(.tertiary)
            }
            VStack(spacing: 10) {
                ForEach(Array(top.enumerated()), id: \.offset) { i, row in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.0).lineLimit(1)
                            Spacer()
                            Text(TokenBadge.short(row.1)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        GeometryReader { geo in
                            Capsule().fill(Color.white.opacity(0.06))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(i == 0 ? honey : bar)
                                        .frame(width: max(4, geo.size.width * CGFloat(row.1) / CGFloat(most)))
                                }
                        }
                        .frame(height: 4)
                    }
                }
            }
        }
    }
}
