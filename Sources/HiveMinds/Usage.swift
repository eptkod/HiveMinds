import SwiftUI

/// How much of the Claude plan's 5-hour and weekly limits is used. Two sources:
/// - While the meter is on screen, the app asks Anthropic every 30 seconds, the same request Claude Code's
///   `/usage` makes, signed in with Claude Code's login from the keychain. This counts Claude used anywhere.
/// - Claude Code also passes the limits to the status line of every agent, which saves them to a file
///   (see `AppStore.writeStatusLineScript`). The app watches that file, so agents' replies show at once.
/// Codex isn't included: there's no comparable way to get its limits from outside.
@MainActor @Observable
final class UsageModel {
    struct Limit: Equatable, Sendable {
        /// 0 to 100.
        var percent: Double
        var resetsAt: Date?

        /// Once the window has reset, nothing in it is used yet.
        func percent(at now: Date) -> Double {
            if let resetsAt, resetsAt <= now { return 0 }
            return percent
        }
    }

    var fiveHour: Limit?
    var week: Limit?
    /// When the numbers shown were last reported.
    var updated: Date?

    var hasData: Bool { fiveHour != nil || week != nil }
    var resetDates: [Date] { [fiveHour?.resetsAt, week?.resetsAt].compactMap { $0 } }

    let file: URL
    @ObservationIgnored private var watch: FileWatch?
    @ObservationIgnored private var refresh: Task<Void, Never>?

    static let refreshInterval: Duration = .seconds(30)

    init(file: URL) {
        self.file = file
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: Data())
        }
        read()
        watch = FileWatch(url: file) { [weak self] in self?.read() }
    }

    /// Asks Anthropic now and then every 30 seconds, until `stopRefreshing`. The meter calls these as it
    /// appears and disappears, so nothing is fetched while it's hidden.
    func startRefreshing() {
        guard refresh == nil else { return }
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                if let (five, seven) = await Self.fetchAccount() {
                    self?.apply(five: five, week: seven, at: Date())
                }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func stopRefreshing() {
        refresh?.cancel()
        refresh = nil
    }

    private func read() {
        // A half-written file doesn't parse; the write that finishes it brings another event.
        guard let data = try? Data(contentsOf: file), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = json["rate_limits"] as? [String: Any] else { return }
        let written = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        apply(five: Self.limit(limits["five_hour"], key: "used_percentage"),
              week: Self.limit(limits["seven_day"], key: "used_percentage"), at: written)
    }

    /// Keeps whichever report is newest, so an old file doesn't replace a fresher fetch.
    private func apply(five: Limit?, week seven: Limit?, at date: Date) {
        guard five != nil || seven != nil else { return }
        if let updated, date < updated { return }
        if five != fiveHour { fiveHour = five }
        if seven != week { week = seven }
        updated = date
    }

    // MARK: Anthropic

    /// The account's current limits, or nil without a Claude Code login or when the request fails
    /// (the next try, 30 seconds later, picks up a token Claude Code has refreshed meanwhile).
    private nonisolated static func fetchAccount() async -> (Limit?, Limit?)? {
        guard let token = await claudeToken() else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (limit(json["five_hour"], key: "utilization"), limit(json["seven_day"], key: "utilization"))
    }

    /// Claude Code's access token. It's read with the `security` tool, which Claude Code itself uses to
    /// save it, so macOS doesn't ask for permission. Older installs keep it in a file instead.
    private nonisolated static func claudeToken() async -> String? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var data = Data()
            if (try? process.run()) != nil {
                data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
            }
            if process.terminationStatus != 0 || data.isEmpty {
                let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
                data = (try? Data(contentsOf: file)) ?? Data()
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = json["claudeAiOauth"] as? [String: Any] else { return nil }
            return oauth["accessToken"] as? String
        }.value
    }

    // MARK: Parsing

    private nonisolated static func limit(_ value: Any?, key: String) -> Limit? {
        guard let d = value as? [String: Any], let used = (d[key] as? NSNumber)?.doubleValue else { return nil }
        return Limit(percent: min(max(used, 0), 100), resetsAt: date(d["resets_at"]))
    }

    /// The status line sends Unix seconds; Anthropic sends ISO 8601 text with microseconds.
    private nonisolated static func date(_ value: Any?) -> Date? {
        if let n = (value as? NSNumber)?.doubleValue {
            return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n)
        }
        if let s = value as? String {
            if let d = try? Date(s, strategy: .iso8601) { return d }
            let whole = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
            return (try? Date(whole, strategy: .iso8601)) ?? Double(s).map { Date(timeIntervalSince1970: $0) }
        }
        return nil
    }
}

/// Calls back whenever a file is written, using a kernel file watch rather than polling.
/// Follows the file if it's replaced rather than written in place.
final class FileWatch {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        open()
    }

    deinit { source?.cancel() }

    private func open() {
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        s.setEventHandler { [weak self, weak s] in
            guard let self, let s else { return }
            if !s.data.isDisjoint(with: [.delete, .rename]) {
                s.cancel()
                self.source = nil
                if !FileManager.default.fileExists(atPath: self.url.path) {
                    FileManager.default.createFile(atPath: self.url.path, contents: Data())
                }
                self.open()
            }
            self.onChange()
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
}

// MARK: Meter

/// The 5-hour and weekly limits, small, at the bottom of the sidebar.
struct UsageMeter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let usage = store.usage
        // Redraws exactly when a window resets, and otherwise only when new numbers come in.
        // `context.date` is the scheduled entry's date (the next reset), not the time now, so it can't be
        // used to decide whether a window has reset; the timeline only triggers the redraw.
        TimelineView(.explicit(usage.resetDates)) { _ in
            let now = Date()
            VStack(alignment: .leading, spacing: 10) {
                Text("Claude plan usage")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if usage.hasData {
                    UsageBar(label: "5-hour", limit: usage.fiveHour, now: now)
                    UsageBar(label: "Week", limit: usage.week, now: now)
                } else {
                    Text("Shows once an agent replies.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        }
        .help(helpText)
        .onAppear { usage.startRefreshing() }
        .onDisappear { usage.stopRefreshing() }
    }

    private var helpText: String {
        var s = "Your Claude account's limits, refreshed every 30 seconds and whenever an agent replies."
        if let updated = store.usage.updated {
            s += " Last updated \(updated.formatted(date: .omitted, time: .shortened))."
        }
        return s
    }
}

private struct UsageBar: View {
    let label: String
    let limit: UsageModel.Limit?
    let now: Date

    var body: some View {
        let percent = limit?.percent(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "–")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                Capsule().fill(Theme.hairline)
                    .overlay(alignment: .leading) {
                        Capsule().fill(color(percent ?? 0))
                            .frame(width: geo.size.width * (percent ?? 0) / 100)
                    }
            }
            .frame(height: 4)
            if let reset = resetText {
                Text(reset).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func color(_ percent: Double) -> Color {
        percent >= 90 ? .red : percent >= 75 ? .orange : Color.white.opacity(0.7)
    }

    private var resetText: String? {
        guard let at = limit?.resetsAt else { return nil }
        let time = at.formatted(date: .omitted, time: .shortened)
        if at <= now { return "Reset at \(time)" }
        if Calendar.current.isDateInToday(at) { return "Resets at \(time)" }
        if Calendar.current.isDateInTomorrow(at) { return "Resets tomorrow at \(time)" }
        return "Resets \(at.formatted(.dateTime.weekday(.wide))) at \(time)"
    }
}
