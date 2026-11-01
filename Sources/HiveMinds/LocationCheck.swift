import SwiftUI
import AppKit
import Network

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

/// The startup region check (Settings > Location). It runs once per launch, only on Wi-Fi. The main window
/// waits for it. If the default provider isn't offered in the country of this Mac's internet address, the only
/// way forward is to quit. If the country can't be found, the app opens with a warning.
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
    private(set) var outcome: Outcome?

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
            #if DEBUG
            print("LOCATION \(result)"); fflush(stdout)
            #endif
            if case .notAllowed(let place, let provider) = result {
                block(place: place, provider: provider)
            } else {
                isChecking = false
            }
        }
    }

    /// A warning for the main window when the check was on but couldn't finish.
    var warning: String? {
        if case .unknown = outcome { return "HiveMinds couldn't work out your region, so it opened without checking." }
        return nil
    }

    /// One line for Settings about how this launch's check went.
    var summary: String? {
        switch outcome {
        case nil: nil
        case .notOnWiFi: "This time: you weren't on Wi-Fi, so nothing was checked."
        case .unknown: "This time: your region couldn't be worked out, so nothing was checked."
        case .allowed(let place, let provider): "This time: \(place). \(provider.label) is available there."
        case .notAllowed(let place, let provider): "This time: \(place). \(provider.label) isn't available there."
        }
    }

    // MARK: The check

    private func check() async -> Outcome {
        let provider = AgentDefaults.provider
        #if DEBUG
        let test = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_LOCATION"]
        if test == "nowifi" { return .notOnWiFi }
        if test == "unknown" { return .unknown }
        if let test, test != "live" { return outcome(provider, country: test) }
        #endif
        guard await isOnWiFi() else { return .notOnWiFi }
        guard let country = await countryOfInternetAddress() else { return .unknown }
        return outcome(provider, country: country)
    }

    private func outcome(_ provider: Provider, country: String) -> Outcome {
        let place = Locale(identifier: "en_US").localizedString(forRegionCode: country) ?? country
        return ProviderRegions.allows(provider, country: country)
            ? .allowed(place: place, provider: provider)
            : .notAllowed(place: place, provider: provider)
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

    /// The error. Its one button quits, and the main window stays closed behind it.
    private func block(place: String, provider: Provider) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "\(provider.label) isn't available in \(place)"
        alert.informativeText = "HiveMinds checked your region because the startup check is on, and your default provider isn't offered there. HiveMinds can't open here."
        alert.addButton(withTitle: "Quit HiveMinds")
        alert.window.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate()
        #if DEBUG
        // `HIVEMINDS_TEST_LOCATION_PRESS=/path.png` saves the alert as a picture, then presses its button.
        if let path = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_LOCATION_PRESS"] {
            let timer = Timer(timeInterval: 1, repeats: false) { _ in
                if let view = alert.window.contentView?.superview ?? alert.window.contentView,
                   let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: image)
                    try? image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                alert.buttons.first?.performClick(nil)
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
        }
        #endif
        alert.runModal()
        NSApp.terminate(nil)
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
                SettingRow(explainer: "Each time HiveMinds starts on Wi-Fi, it checks which country your internet address is in. If your default provider, \(providerLabel), isn't offered there, you get an error and can only quit. You can change the provider in Settings > Agents.") {
                    Toggle("Check my region at startup", isOn: $on)
                }
                if on, let summary = check.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("HiveMinds never uses your Mac's precise location. It asks Cloudflare for your internet address's country and saves nothing, and a VPN changes the answer. If the country can't be found, the app opens with a warning. The country lists come from Anthropic and OpenAI, as of November 2026.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}
