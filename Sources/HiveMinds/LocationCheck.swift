import SwiftUI
import AppKit
import Network
import HiveMindsCore
import HiveMindsProtocol

/// Where each provider says it can be used. Copied from the providers' own pages on 2026-11-01:
/// anthropic.com/supported-countries (effective 2026-11-12) and developers.openai.com/api/docs/supported-countries.
/// OpenAI's page doesn't name Codex, so its list stands in for Codex. These are ISO country codes.
enum ProviderRegions {
    static func countries(for provider: Provider) -> Set<String> {
        switch provider {
        case .claude: claude
        case .codex: codex
        }
    }

    static func allows(_ provider: Provider, country: String) -> Bool {
        countries(for: provider).contains(country.uppercased())
    }

    private static func codes(_ list: String) -> Set<String> { Set(list.split(separator: " ").map(String.init)) }

    private static let claude = codes("""
        AD AE AG AL AM AO AR AT AU AZ BA BB BD BE BF BG BH BI BJ BN BO BR BS BT BW BZ CA CD CF CG CH CI CL CM CO CR CV CY CZ \
        DE DJ DK DM DO DZ EC EE EG ER ES ET FI FJ FM FR GA GB GD GE GH GM GN GQ GR GT GW GY HN HR HT HU ID IE IL IN IQ IS IT \
        JM JO JP KE KG KH KI KM KN KR KW KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MG MH MK ML MN MR MT MU MV MW MX MY \
        MZ NA NE NG NI NL NO NP NR NZ OM PA PE PG PH PK PL PS PT PW PY QA RO RS RW SA SB SC SD SE SG SI SK SL SM SN SO SR SS \
        ST SV SZ TD TG TH TJ TL TM TN TO TR TT TV TW TZ UA UG US UY UZ VA VC VN VU WS ZA ZM ZW
        """)

    private static let codex = codes("""
        AD AE AF AG AL AM AO AR AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BR BS BT BW BZ CA CD CF CG CH CI CL CM \
        CO CR CV CY CZ DE DJ DK DM DO DZ EC EE EG ER ES ET FI FJ FM FO FR GA GB GD GE GF GH GL GM GN GP GQ GR GT GW GY HN HR \
        HT HU ID IE IL IN IQ IS IT JM JO JP KE KG KH KI KM KN KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG \
        MH MK ML MM MN MQ MR MT MU MV MW MX MY MZ NA NC NE NG NI NL NO NP NR NZ OM PA PE PF PG PH PK PL PM PS PT PW PY QA RE \
        RO RS RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SZ TD TF TG TH TJ TL TM TN TO TR TT TV TW TZ UA UG US \
        UY UZ VA VC VN VU WF WS YE YT ZA ZM ZW
        """)
}

/// The region check (Settings > Location). It runs at launch, only on Wi-Fi, and the main window waits for it.
/// While the app is open it also re-checks whenever the network changes (a VPN turning off, a new Wi-Fi network,
/// waking from sleep). That uses the system's own network-change events, so nothing polls.
/// If a provider in use isn't offered in the country of this Mac's internet address, every agent and meeting is
/// stopped, the main window's content is hidden, and an error offers Quit or turning the check off (so a wrong
/// answer can never lock anyone out). If the country can't be found, the app carries on.
/// It never uses Location Services, and only the country code is read from the reply. Nothing is saved.
@MainActor @Observable
final class LocationCheck {
    static let shared = LocationCheck()

    enum Outcome {
        case notOnWiFi, unknown
        case allowed(place: String, provider: Provider)
        case notAllowed(place: String, provider: Provider)
    }

    /// True until the main window may open.
    private(set) var isChecking: Bool
    /// True while the block error is up, so the main window shows nothing behind it.
    private(set) var isBlocked = false
    private(set) var outcome: Outcome?
    @ObservationIgnored weak var store: AppStore?

    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var wake: NSObjectProtocol?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var seenFirstPath = false

    @ObservationIgnored private var turnedOffHere = false

    private var isOn: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HIVEMINDS_TEST_LOCATION"] != nil { return !turnedOffHere }
        #endif
        return UserDefaults.standard.object(forKey: SettingKey.locationCheck) as? Bool ?? SettingDefault.locationCheck
    }

    init() {
        var on = UserDefaults.standard.object(forKey: SettingKey.locationCheck) as? Bool ?? SettingDefault.locationCheck
        #if DEBUG
        if ProcessInfo.processInfo.environment["HIVEMINDS_TEST_LOCATION"] != nil { on = true }
        #endif
        isChecking = on
    }

    /// Called once when the app finishes launching.
    func run() {
        guard isChecking else { return }
        Task {
            let result = await check()
            outcome = result
            log("LOCATION \(result)")
            if case .notAllowed(let place, let provider) = result {
                block(place: place, provider: provider, atLaunch: true)
            } else {
                isChecking = false
                watch()
            }
        }
    }

    /// Settings > Location calls this when the switch changes. Turning it on checks straight away.
    func settingChanged(_ on: Bool) {
        if on {
            watch()
            recheck(after: 0)
        } else {
            stopWatching()
        }
    }

    /// A warning for the main window when the check was on but couldn't finish.
    var warning: String? {
        if case .unknown = outcome { return "HiveMinds couldn't work out your region, so it opened without checking." }
        return nil
    }

    /// One line for Settings about how the last check went.
    var summary: String? {
        switch outcome {
        case nil: nil
        case .notOnWiFi: "Last check: you weren't on Wi-Fi, so nothing was checked."
        case .unknown: "Last check: your region couldn't be worked out, so nothing was checked."
        case .allowed(let place, let provider): "Last check: \(place). \(provider.label) is available there."
        case .notAllowed(let place, let provider): "Last check: \(place). \(provider.label) isn't available there."
        }
    }

    // MARK: Watching for network changes

    /// Starts listening for network changes and wake from sleep. Does nothing if it's already listening.
    private func watch() {
        guard isOn, monitor == nil else { return }
        seenFirstPath = false
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The first update only reports how things are now.
                if !self.seenFirstPath { self.seenFirstPath = true; return }
                self.recheck(after: 3)
            }
        }
        monitor.start(queue: .main)
        self.monitor = monitor
        wake = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.recheck(after: 5) }
        }
        #if DEBUG
        // `HIVEMINDS_TEST_LOCATION_CHANGE=<code>` acts as if the network changed to that country, 3 s after launch
        // or after `HIVEMINDS_TEST_LOCATION_CHANGE_AFTER` seconds.
        let env = ProcessInfo.processInfo.environment
        if env["HIVEMINDS_TEST_LOCATION_CHANGE"] != nil {
            let after = Double(env["HIVEMINDS_TEST_LOCATION_CHANGE_AFTER"] ?? "3") ?? 3
            Task { try? await Task.sleep(for: .seconds(after)); self.recheck(after: 0) }
        }
        #endif
    }

    private func stopWatching() {
        monitor?.cancel()
        monitor = nil
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        wake = nil
        pending?.cancel()
        pending = nil
    }

    /// Checks again once the network has settled. Network changes come in bursts, so each one restarts the wait.
    /// If the answer is unknown (a VPN still connecting, say), it tries once more before leaving things as they are.
    private func recheck(after seconds: Double) {
        pending?.cancel()
        pending = Task {
            if seconds > 0 { try? await Task.sleep(for: .seconds(seconds)) }
            guard !Task.isCancelled, isOn, !isBlocked else { return }
            var result = await check()
            if case .unknown = result {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, isOn, !isBlocked else { return }
                result = await check()
            }
            guard !Task.isCancelled, isOn, !isBlocked else { return }
            log("LOCATION RECHECK \(result)")
            outcome = result
            if case .notAllowed(let place, let provider) = result {
                block(place: place, provider: provider, atLaunch: false)
            }
        }
    }

    private func log(_ line: String) {
        #if DEBUG
        print(line); fflush(stdout)
        #endif
    }

    // MARK: The check

    /// The default provider, plus any other provider an agent is running with right now.
    private var providersInUse: [Provider] {
        var list = [AgentDefaults.provider]
        if let store {
            for a in store.agents where Terminals.shared.isRunning(a.id) && !list.contains(a.provider) {
                list.append(a.provider)
            }
        }
        return list
    }

    private func check() async -> Outcome {
        let providers = providersInUse
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        var test = env["HIVEMINDS_TEST_LOCATION"]
        if !isChecking, let change = env["HIVEMINDS_TEST_LOCATION_CHANGE"] { test = change }
        if test == "nowifi" { return .notOnWiFi }
        if test == "unknown" { return .unknown }
        if let test, test != "live" { return outcome(providers, country: test) }
        #endif
        guard await isOnWiFi() else { return .notOnWiFi }
        guard let country = await countryOfInternetAddress() else { return .unknown }
        return outcome(providers, country: country)
    }

    private func outcome(_ providers: [Provider], country: String) -> Outcome {
        let place = Locale(identifier: "en_US").localizedString(forRegionCode: country) ?? country
        if let blocked = providers.first(where: { !ProviderRegions.allows($0, country: country) }) {
            return .notAllowed(place: place, provider: blocked)
        }
        return .allowed(place: place, provider: providers[0])
    }

    private func isOnWiFi() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let monitor = NWPathMonitor(requiredInterfaceType: .wifi)
            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                done.resume(returning: path.status == .satisfied)
            }
            monitor.start(queue: .main)
        }
    }

    /// Asks Cloudflare which country this Mac's internet address is in. It answers with a few `key=value` lines,
    /// and only `loc` is read. Anything that isn't a real country code (it uses XX for unknown and T1 for Tor)
    /// counts as not knowing. Waits at most 6 seconds, so a bad connection can't hold the app shut.
    private func countryOfInternetAddress() async -> String? {
        var address = "https://www.cloudflare.com/cdn-cgi/trace"
        #if DEBUG
        if let url = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_LOCATION_URL"] { address = url }
        #endif
        guard let url = URL(string: address) else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 6
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first(where: { $0.hasPrefix("loc=") })
        else { return nil }
        let code = line.dropFirst(4).uppercased()
        return Locale.Region.isoRegions.contains { $0.identifier == code } ? code : nil
    }

    /// The error. At launch the main window stays closed behind it; later, every agent and meeting is stopped
    /// first and the window's content is hidden. Quit quits. Turn Off Region Check is the way out if the answer
    /// is wrong or a VPN is misbehaving: it turns the setting off and lets the app open (or carry on).
    private func block(place: String, provider: Provider, atLaunch: Bool) {
        if !atLaunch, let store {
            log("LOCATION BEFORE running=\(store.agents.filter { Terminals.shared.isRunning($0.id) }.count) "
                + "meetings=\(store.meetings.map(\.status.rawValue)) agents=\(store.agents.map { store.state($0.id).status.rawValue })")
            store.stopEverything("Stopped: \(provider.label) isn't available in \(place)")
            log("LOCATION STOPPED running=\(store.agents.filter { Terminals.shared.isRunning($0.id) }.count) "
                + "meetings=\(store.meetings.map(\.status.rawValue)) agents=\(store.agents.map { store.state($0.id).status.rawValue })")
        }
        isBlocked = true
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(provider.label) isn't available in \(place)"
        alert.informativeText = atLaunch
            ? "HiveMinds checked your region because the region check is on, and \(provider.label) isn't offered where your internet address is. HiveMinds can't open here.\n\nIf this is wrong, turn the check off to open HiveMinds anyway. You can turn it back on in Settings > Location."
            : "Your network changed (a VPN may have turned off), and \(provider.label) isn't offered where your internet address is now. HiveMinds stopped all agents and meetings.\n\nIf this is wrong, turn the check off to carry on. Stopped agents pick up where they left off when started again. You can turn the check back on in Settings > Location."
        alert.addButton(withTitle: "Quit HiveMinds")
        alert.addButton(withTitle: "Turn Off Region Check")
        alert.window.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate()
        #if DEBUG
        // `HIVEMINDS_TEST_LOCATION_PRESS=/path.png` saves the alert as a picture, then presses its first button,
        // or the one numbered by `HIVEMINDS_TEST_LOCATION_BUTTON` (1 = Quit, 2 = Turn Off).
        let env = ProcessInfo.processInfo.environment
        if let path = env["HIVEMINDS_TEST_LOCATION_PRESS"] {
            let index = (Int(env["HIVEMINDS_TEST_LOCATION_BUTTON"] ?? "1") ?? 1) - 1
            let timer = Timer(timeInterval: 1, repeats: false) { _ in
                MainActor.assumeIsolated {
                    if let view = alert.window.contentView?.superview ?? alert.window.contentView,
                       let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: image)
                        try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    }
                    alert.buttons[min(index, alert.buttons.count - 1)].performClick(nil)
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        #endif
        let choice = alert.runModal()
        guard choice == .alertSecondButtonReturn else { NSApp.terminate(nil); return }
        log("LOCATION TURNED OFF")
        turnedOffHere = true
        UserDefaults.standard.set(false, forKey: SettingKey.locationCheck)
        stopWatching()
        isBlocked = false
        isChecking = false
        if !atLaunch { store?.notice = "The region check is off. Start your agents again when you're ready." }
    }
}

/// What the main window shows behind the block error, in place of everything else.
struct LocationBlockedView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "location.slash")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("HiveMinds is paused because your region changed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What the main window shows while the check runs, so nothing opens before it's finished.
struct LocationCheckingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Checking your region…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct LocationSettings: View {
    @AppStorage(SettingKey.locationCheck) private var on = SettingDefault.locationCheck
    @AppStorage(SettingKey.defaultProvider) private var provider = SettingDefault.defaultProvider
    private let check = LocationCheck.shared

    private var providerLabel: String { (Provider(rawValue: provider) ?? .claude).label }

    var body: some View {
        Form {
            Section {
                SettingRow(explainer: "When HiveMinds starts on Wi-Fi, and again whenever your network changes (for example a VPN turning off), it checks which country your internet address is in. If your default provider, \(providerLabel), or one your agents are running on isn't offered there, every agent stops and you can quit or turn this off. You can change the provider in Settings > Agents.") {
                    Toggle("Check my region", isOn: $on)
                }
                if on, let summary = check.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Region")
            } footer: {
                Text("HiveMinds never uses your Mac's precise location. It asks Cloudflare for your internet address's country and saves nothing, and a VPN changes the answer. If the country can't be found, HiveMinds carries on (at startup, with a warning). The country lists come from Anthropic and OpenAI, as of November 2026.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: on) { _, now in check.settingChanged(now) }
    }
}
