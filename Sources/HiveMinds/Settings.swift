import SwiftUI
import AppKit
import AVFoundation

/// Settings are stored in UserDefaults through @AppStorage, so they're kept when the app quits.
enum SettingKey {
    static let backgroundOpacity = "ui.backgroundOpacity"
    static let blurRadius = "ui.blurRadius"
    static let showUsage = "ui.showUsage"
    /// What the Overview's activity charts measure: tokens or hours.
    static let overviewMetric = "ui.overviewMetric"
    static let defaultProvider = "agents.defaultProvider"
    static let defaultModel = "agents.defaultModel"
    static let defaultEffort = "agents.defaultEffort"
    static let ownBranch = "agents.ownBranch"
    static let defaultAccess = "agents.defaultAccess"
    static let defaultRole = "agents.defaultRole"
    static let autoTitles = "agents.autoTitles"
    /// Estimated cost, in dollars, at which an agent gets a warning. 0 is off.
    static let costWarning = "agents.costWarning"
    /// How many deleted agents the History page keeps, and for how many days.
    static let historyLimit = "agents.historyLimit"
    static let historyDays = "agents.historyDays"
    /// Stop the display and Mac from sleeping while any agent is working.
    static let keepAwake = "agents.keepAwake"
    static let meetingModel = "meetings.model"
    static let meetingSeats = "meetings.seats"
    static let meetingRounds = "meetings.rounds"
    static let meetingAcceptEdits = "meetings.acceptEdits"
    static let meetingCommit = "meetings.commit"
    static let meetingOutcomeFolder = "meetings.outcomeFolder"
    static let meetingEndEarly = "meetings.endEarly"
    static let meetingSplitModels = "meetings.splitModels"
    static let meetingOtherModel = "meetings.otherModel"
    static let settingsTab = "settings.tab"
    /// Which part of the GitHub page is showing: repositories or issues.
    static let githubTab = "github.tab"
    static let projectsFolder = "projects.folder"
    static let soundsOn = "sounds.on"
    static let soundVolume = "sounds.volume"
    static let voiceOn = "voice.on"
    static let voiceEngine = "voice.engine"
    static let voiceKey = "voice.key"
    /// Hold the key while talking, or tap it to start and again to stop.
    static let voiceHold = "voice.hold"
    static let voiceLanguage = "voice.language"
    static let voiceModel = "voice.model"
    static let voiceVocabulary = "voice.vocabulary"
    /// Whether one kind of moment (permission, question, error, done) makes its sound.
    static func sound(_ cue: Cue) -> String { "sounds.\(cue.rawValue)" }
    /// How each provider signs in: "plan" or "apiKey". The key itself is in the Keychain.
    static func signIn(_ provider: Provider) -> String { "signIn.\(provider.rawValue)" }
}

enum SettingDefault {
    static let backgroundOpacity = 0.78
    static let blurRadius = 24.0
    static let opacityRange = 0.2...1.0
    static let blurRange = 0.0...60.0
    static let showUsage = true
    static let defaultProvider = Provider.claude.rawValue
    static let defaultModel = "default"
    static let defaultEffort = Effort.medium.rawValue
    static let ownBranch = true
    static let defaultAccess = Access.auto.rawValue
    static let defaultRole = ""
    static let autoTitles = true
    static let costWarning = 10.0
    static let costWarningChoices: [Double] = [0, 1, 5, 10, 25, 50, 100]
    static let historyLimit = 100
    static let historyLimitChoices = [25, 50, 100, 250, 500]
    static let historyDays = 7
    static let historyDaysChoices = [1, 3, 7, 14, 30]
    static let keepAwake = false
    static let meetingModel = "default"
    static let meetingSeats = 3
    static let meetingRounds = 2
    static let meetingAcceptEdits = true
    static let meetingCommit = true
    static let meetingOutcomeFolder = "meetings"
    static let meetingEndEarly = true
    static let meetingSplitModels = false
    static let meetingOtherModel = "sonnet"
    /// Empty until the first GitHub download asks for a folder.
    static let projectsFolder = ""
    static let signIn = SignIn.plan.rawValue
    static let soundsOn = true
    static let soundVolume = 0.6
    static let voiceOn = false
    static let voiceEngine = VoiceEngine.apple.rawValue
    static let voiceKey = VoiceKey.rightOption.rawValue
    static let voiceHold = true
    static let voiceLanguage = "auto"
    static let voiceModel = "base.en"
    static let voiceVocabulary = ""
    static let sound = true
}

/// The agent settings as plain values, for code outside a view (the New Agent sheet, the store).
enum AgentDefaults {
    private static var d: UserDefaults { .standard }
    static var provider: Provider { Provider(rawValue: d.string(forKey: SettingKey.defaultProvider) ?? "") ?? .claude }
    static var model: String { d.string(forKey: SettingKey.defaultModel) ?? SettingDefault.defaultModel }
    static var effort: Effort { Effort(rawValue: d.string(forKey: SettingKey.defaultEffort) ?? "") ?? .medium }
    static var access: Access { Access(rawValue: d.string(forKey: SettingKey.defaultAccess) ?? "") ?? .auto }
    static var ownBranch: Bool { d.object(forKey: SettingKey.ownBranch) as? Bool ?? SettingDefault.ownBranch }
    static var role: String { d.string(forKey: SettingKey.defaultRole) ?? SettingDefault.defaultRole }
    static var autoTitles: Bool { d.object(forKey: SettingKey.autoTitles) as? Bool ?? SettingDefault.autoTitles }
    static var costWarning: Double { d.object(forKey: SettingKey.costWarning) as? Double ?? SettingDefault.costWarning }
    static var historyLimit: Int { d.object(forKey: SettingKey.historyLimit) as? Int ?? SettingDefault.historyLimit }
    static var historyDays: Int { d.object(forKey: SettingKey.historyDays) as? Int ?? SettingDefault.historyDays }
}

/// Where projects downloaded from GitHub go: `<folder>/<repo>`, or `<folder>/<owner>-<repo>` if that name is taken.
enum ProjectFolder {
    static var path: String? {
        let p = UserDefaults.standard.string(forKey: SettingKey.projectsFolder) ?? SettingDefault.projectsFolder
        return p.isEmpty ? nil : p
    }

    static var suggested: String { NSHomeDirectory() + "/HiveMinds/projects" }

    static func destinations(for repo: String, in folder: String) -> [String] {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [folder + "/" + repo] }
        return ["\(folder)/\(parts[1])", "\(folder)/\(parts[0])-\(parts[1])"]
    }

    /// Asks for the folder and saves it. Returns nil if cancelled.
    @MainActor @discardableResult
    static func choose(firstTime: Bool = false) -> String? {
        let start = path ?? suggested
        try? FileManager.default.createDirectory(atPath: start, withIntermediateDirectories: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: start)
        panel.prompt = "Use This Folder"
        panel.message = firstTime
            ? "Where should projects from GitHub go? Each one gets its own folder inside. You can change this later in Settings > Projects."
            : "Where should projects from GitHub go? Each one gets its own folder inside."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let chosen = (url.path as NSString).standardizingPath
        UserDefaults.standard.set(chosen, forKey: SettingKey.projectsFolder)
        return chosen
    }
}

// MARK: Window look

/// Makes a window see-through to the desktop, tinted black, with the chosen blur behind it.
struct WindowAppearance: ViewModifier {
    @AppStorage(SettingKey.backgroundOpacity) private var opacity = SettingDefault.backgroundOpacity
    @AppStorage(SettingKey.blurRadius) private var blur = SettingDefault.blurRadius

    func body(content: Content) -> some View {
        content
            .containerBackground(Color.black.opacity(clampedOpacity), for: .window)
            .background(WindowConfigurator(blur: Int(blur.rounded())))
            .onChange(of: opacity, initial: true) { _, _ in Terminals.shared.applyAppearance(); Shells.shared.applyAppearance() }
    }

    private var clampedOpacity: Double {
        min(max(opacity, SettingDefault.opacityRange.lowerBound), SettingDefault.opacityRange.upperBound)
    }
}

/// Reaches the NSWindow behind a SwiftUI view to turn off its opaque backing and set the blur.
private struct WindowConfigurator: NSViewRepresentable {
    let blur: Int

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { apply(to: view.window) }
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        WindowBlur.set(window, radius: blur)
    }
}

/// The blur behind a window. macOS has no public API for its strength; this uses the same private
/// CoreGraphics call as iTerm2's blur setting, looked up at run time so a future macOS without it
/// simply shows no blur instead of crashing.
enum WindowBlur {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SetRadius = @convention(c) (Int32, UInt32, Int32) -> Int32

    private static let functions: (MainConnection, SetRadius)? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let c = dlsym(handle, "CGSMainConnectionID"),
              let s = dlsym(handle, "CGSSetWindowBackgroundBlurRadius") else { return nil }
        return (unsafeBitCast(c, to: MainConnection.self), unsafeBitCast(s, to: SetRadius.self))
    }()

    @discardableResult
    static func set(_ window: NSWindow, radius: Int) -> Bool {
        guard let (connection, setRadius) = functions, window.windowNumber > 0 else { return false }
        return setRadius(connection(), UInt32(window.windowNumber), Int32(max(0, radius))) == 0
    }
}

// MARK: Settings window

struct SettingsView: View {
    /// Reopens on the tab you last looked at.
    @AppStorage(SettingKey.settingsTab) private var tab = "appearance"

    var body: some View {
        TabView(selection: $tab) {
            Tab("Appearance", systemImage: "paintbrush", value: "appearance") {
                AppearanceSettings()
            }
            Tab("Agents", systemImage: "person.2", value: "agents") {
                AgentSettings()
            }
            Tab("Meetings", systemImage: "bubble.left.and.bubble.right", value: "meetings") {
                MeetingSettings()
            }
            Tab("Sounds", systemImage: "speaker.wave.2", value: "sounds") {
                SoundSettings()
            }
            Tab("Voice", systemImage: "mic", value: "voice") {
                VoiceSettings()
            }
            Tab("Projects", systemImage: "folder", value: "projects") {
                ProjectSettings()
            }
            Tab("Accounts", systemImage: "key", value: "accounts") {
                AccountSettings()
            }
        }
        .frame(width: 540)
        .preferredColorScheme(.dark)
        .modifier(WindowAppearance())
    }
}

struct AppearanceSettings: View {
    @AppStorage(SettingKey.backgroundOpacity) private var opacity = SettingDefault.backgroundOpacity
    @AppStorage(SettingKey.blurRadius) private var blur = SettingDefault.blurRadius
    @AppStorage(SettingKey.showUsage) private var showUsage = SettingDefault.showUsage

    var body: some View {
        Form {
            Section {
                SettingSlider(title: "Background opacity",
                              explainer: "How much of your desktop shows through. 100% is solid black.",
                              value: $opacity, range: SettingDefault.opacityRange,
                              lowIcon: "circle.dotted", highIcon: "circle.fill",
                              valueText: "\(Int((opacity * 100).rounded()))%")
                SettingSlider(title: "Background blur",
                              explainer: opacity >= 1
                                ? "Blur shows once the background opacity is below 100%."
                                : "Softens whatever shows through behind the window.",
                              value: $blur, range: SettingDefault.blurRange,
                              lowIcon: "drop", highIcon: "drop.fill",
                              valueText: blur < 0.5 ? "Off" : "\(Int(blur.rounded()))")
            } header: {
                Text("Window")
            } footer: {
                Text("Changes show right away and are kept when you reopen HiveMinds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingRow(explainer: "Your Claude plan's 5-hour and weekly limits, read from Claude Code as your agents work. Codex agents aren't counted.") {
                    Toggle("Show plan usage", isOn: $showUsage)
                }
            } header: {
                Text("Sidebar")
            } footer: {
                // In the footer, not its own section, so it doesn't sit in an otherwise empty card.
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        opacity = SettingDefault.backgroundOpacity
                        blur = SettingDefault.blurRadius
                        showUsage = SettingDefault.showUsage
                    }
                    .disabled(opacity == SettingDefault.backgroundOpacity && blur == SettingDefault.blurRadius
                              && showUsage == SettingDefault.showUsage)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// What a new agent starts with. The New Agent sheet opens with these, and Options there changes them for one agent.
struct AgentSettings: View {
    @Environment(AppStore.self) private var store
    @AppStorage(SettingKey.defaultProvider) private var provider = SettingDefault.defaultProvider
    @AppStorage(SettingKey.defaultModel) private var model = SettingDefault.defaultModel
    @AppStorage(SettingKey.defaultEffort) private var effort = SettingDefault.defaultEffort
    @AppStorage(SettingKey.ownBranch) private var ownBranch = SettingDefault.ownBranch
    @AppStorage(SettingKey.defaultAccess) private var access = SettingDefault.defaultAccess
    @AppStorage(SettingKey.defaultRole) private var role = SettingDefault.defaultRole
    @AppStorage(SettingKey.autoTitles) private var autoTitles = SettingDefault.autoTitles
    @AppStorage(SettingKey.costWarning) private var costWarning = SettingDefault.costWarning
    @AppStorage(SettingKey.historyLimit) private var historyLimit = SettingDefault.historyLimit
    @AppStorage(SettingKey.historyDays) private var historyDays = SettingDefault.historyDays
    @AppStorage(SettingKey.keepAwake) private var keepAwake = SettingDefault.keepAwake

    private var isDefault: Bool {
        provider == SettingDefault.defaultProvider && model == SettingDefault.defaultModel
            && effort == SettingDefault.defaultEffort && ownBranch == SettingDefault.ownBranch && access == SettingDefault.defaultAccess && role == SettingDefault.defaultRole
            && autoTitles == SettingDefault.autoTitles && costWarning == SettingDefault.costWarning
            && historyLimit == SettingDefault.historyLimit && historyDays == SettingDefault.historyDays
            && keepAwake == SettingDefault.keepAwake
    }

    private var costExplainer: String {
        if store.tools.claude == nil { return "Usage unavailable: cost estimates come from Claude Code, which isn't installed." }
        if costWarning == 0 { return "Off. You won't be warned about what an agent costs." }
        return "Shows a warning once when an agent passes this, at Claude API prices. It's an estimate, nothing is paused, and Codex agents aren't counted."
    }

    var body: some View {
        Form {
            Section {
                if store.tools.providers.count > 1 {
                    SettingRow(explainer: "The command-line tool new agents run in.") {
                        Picker("Runs on", selection: $provider) {
                            ForEach(store.tools.providers) { Text($0.label).tag($0.rawValue) }
                        }
                    }
                }
                SettingRow(explainer: "Default lets Claude Code choose. Opus is the most capable, Haiku the fastest.") {
                    Picker("Claude Code model", selection: $model) {
                        ForEach(Provider.claude.models, id: \.self) { Text($0 == "default" ? "Default" : $0.capitalized).tag($0) }
                    }
                }
                SettingRow(explainer: "How hard agents think before answering. Higher is slower and uses more of your plan. Works for Claude Code and Codex; Codex tops out at Extra high, so Max gives it that.") {
                    Picker("Effort", selection: $effort) {
                        ForEach(Effort.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    // An earlier build could save "default", which isn't a level any more.
                    .onAppear { if Effort(rawValue: effort) == nil { effort = SettingDefault.defaultEffort } }
                }
                SettingRow(explainer: (Access(rawValue: access) ?? .auto).explainer) {
                    Picker("Access", selection: $access) {
                        ForEach(Access.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
                SettingRow(explainer: "Each agent works on its own git branch, so you can review its changes as a pull request. Only applies in git projects.") {
                    Toggle("Own branch", isOn: $ownBranch)
                }
                SettingRow(explainer: "Extra instructions every new Claude Code agent gets. You can still change them per agent.") {
                    TextField("Role", text: $role, prompt: Text("e.g. careful reviewer who writes tests first"), axis: .vertical)
                        .lineLimit(1...4)
                }
            } header: {
                Text("New agents")
            } footer: {
                Text("These only change what new agents start with. Agents you already have keep their settings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingRow(explainer: "Claude Haiku writes a short title from each chat's first request. Uses a little of your Claude plan. When off, the title is the start of the request.") {
                    Toggle("Name chats automatically", isOn: $autoTitles)
                }
                SettingRow(explainer: costExplainer) {
                    Picker("Warn when an agent costs", selection: $costWarning) {
                        ForEach(SettingDefault.costWarningChoices, id: \.self) { v in
                            Text(v == 0 ? "Off" : "$\(Int(v))").tag(v)
                        }
                    }
                    .disabled(store.tools.claude == nil)
                }
            } header: {
                Text("Chats")
            }

            Section {
                SettingRow(explainer: "Your display won't turn off and your Mac won't sleep while any agent is working, even if you leave it alone. Normal sleep comes back once they're all finished or waiting on you.") {
                    Toggle("Stay awake while agents work", isOn: $keepAwake)
                }
            } header: {
                Text("Sleep")
            }

            Section {
                SettingRow(explainer: "The History page keeps this many deleted agents. The oldest go first.") {
                    Picker("Keep up to", selection: $historyLimit) {
                        ForEach(SettingDefault.historyLimitChoices, id: \.self) { Text("\($0) agents").tag($0) }
                    }
                }
                SettingRow(explainer: "Deleted agents leave the History page this long after they were deleted. Agents you still have are always shown.") {
                    Picker("Keep for", selection: $historyDays) {
                        ForEach(SettingDefault.historyDaysChoices, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                    }
                }
            } header: {
                Text("History")
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        provider = SettingDefault.defaultProvider
                        model = SettingDefault.defaultModel
                        effort = SettingDefault.defaultEffort
                        ownBranch = SettingDefault.ownBranch
                        access = SettingDefault.defaultAccess
                        role = SettingDefault.defaultRole
                        autoTitles = SettingDefault.autoTitles
                        costWarning = SettingDefault.costWarning
                        historyLimit = SettingDefault.historyLimit
                        historyDays = SettingDefault.historyDays
                        keepAwake = SettingDefault.keepAwake
                    }
                    .disabled(isDefault)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: historyLimit) { store.history.trim() }
        .onChange(of: historyDays) { store.history.trim() }
        .onChange(of: keepAwake) { KeepAwake.apply() }
    }
}

/// The Claude models to pick from, for meeting model pickers.
@ViewBuilder var modelOptions: some View {
    ForEach(Provider.claude.models, id: \.self) { Text($0 == "default" ? "Default" : $0.capitalized).tag($0) }
}

/// What a new meeting starts with. The New Meeting sheet opens with these.
struct MeetingSettings: View {
    @AppStorage(SettingKey.meetingModel) private var model = SettingDefault.meetingModel
    @AppStorage(SettingKey.meetingSeats) private var seats = SettingDefault.meetingSeats
    @AppStorage(SettingKey.meetingRounds) private var rounds = SettingDefault.meetingRounds
    @AppStorage(SettingKey.meetingAcceptEdits) private var acceptEdits = SettingDefault.meetingAcceptEdits
    @AppStorage(SettingKey.meetingCommit) private var commit = SettingDefault.meetingCommit
    @AppStorage(SettingKey.meetingOutcomeFolder) private var outcomeFolder = SettingDefault.meetingOutcomeFolder
    @AppStorage(SettingKey.meetingEndEarly) private var endEarly = SettingDefault.meetingEndEarly
    @AppStorage(SettingKey.meetingSplitModels) private var splitModels = SettingDefault.meetingSplitModels
    @AppStorage(SettingKey.meetingOtherModel) private var otherModel = SettingDefault.meetingOtherModel

    private var isDefault: Bool {
        model == SettingDefault.meetingModel && seats == SettingDefault.meetingSeats && rounds == SettingDefault.meetingRounds
            && acceptEdits == SettingDefault.meetingAcceptEdits && commit == SettingDefault.meetingCommit
            && outcomeFolder == SettingDefault.meetingOutcomeFolder && endEarly == SettingDefault.meetingEndEarly
            && splitModels == SettingDefault.meetingSplitModels && otherModel == SettingDefault.meetingOtherModel
    }

    var body: some View {
        Form {
            Section {
                SettingRow(explainer: splitModels
                           ? "The model of the seat that runs the meeting: the chair, lead, head or red."
                           : "The model every seat at the table uses. Meetings run several sessions at once, so they use more of your plan.") {
                    Picker(splitModels ? "Lead seat's model" : "Model", selection: $model) { modelOptions }
                }
                SettingRow(explainer: "Lets the seat that runs the meeting use a stronger model than the rest of the table, e.g. Fable to chair and Opus or Sonnet to debate. A cheaper model for the rest saves tokens.") {
                    Toggle("Use a different model for the other seats", isOn: $splitModels.animation())
                }
                if splitModels {
                    SettingRow(explainer: "The model every other seat uses: debaters, team members, mappers, blue and reviewers.") {
                        Picker("Other seats' model", selection: $otherModel) { modelOptions }
                    }
                }
                SettingRow(explainer: "How many agents sit at the table. Red / blue always has two.") {
                    Stepper("Agents: \(seats)", value: $seats, in: 2...5)
                }
                SettingRow(explainer: "Rounds of critique, review or attack, for the formats that have them.") {
                    Stepper("Rounds: \(rounds)", value: $rounds, in: 1...4)
                }
                SettingRow(explainer: "Skips the remaining rounds once the seats agree, the lead has nothing left to change, or red finds nothing. Saves tokens.") {
                    Toggle("End early when settled", isOn: $endEarly)
                }
            } header: {
                Text("New meetings")
            }

            Section {
                SettingRow(explainer: "Seats use the access level from Settings > Agents. This only matters on Manual review: seats then write files without asking, but still ask before running commands.") {
                    Toggle("Let agents edit files without asking", isOn: $acceptEdits)
                }
                SettingRow(explainer: "Meetings in a git project run on their own branch. When one finishes, its outcome and changes are committed there. Nothing is pushed.") {
                    Toggle("Commit the outcome", isOn: $commit)
                }
                SettingRow(explainer: "Each meeting's outcome is saved here, inside the project's folder, named by date and topic.") {
                    TextField("Outcome folder", text: $outcomeFolder, prompt: Text(SettingDefault.meetingOutcomeFolder))
                }
            } header: {
                Text("While they run")
            } footer: {
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        model = SettingDefault.meetingModel
                        seats = SettingDefault.meetingSeats
                        rounds = SettingDefault.meetingRounds
                        acceptEdits = SettingDefault.meetingAcceptEdits
                        commit = SettingDefault.meetingCommit
                        outcomeFolder = SettingDefault.meetingOutcomeFolder
                        endEarly = SettingDefault.meetingEndEarly
                        splitModels = SettingDefault.meetingSplitModels
                        otherModel = SettingDefault.meetingOtherModel
                    }
                    .disabled(isDefault)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Which moments make a sound, and how loud. Each kind has its own sound so you know what happened without looking.
struct SoundSettings: View {
    @AppStorage(SettingKey.soundsOn) private var on = SettingDefault.soundsOn
    @AppStorage(SettingKey.soundVolume) private var volume = SettingDefault.soundVolume

    var body: some View {
        Form {
            Section {
                SettingRow(explainer: "Plays a short sound when an agent needs you or something happens. Each kind has its own sound.") {
                    Toggle("Play sounds", isOn: $on)
                }
                if on {
                    SettingSlider(title: "Volume",
                                  explainer: "Relative to your Mac's volume.",
                                  value: $volume, range: 0.1...1,
                                  lowIcon: "speaker", highIcon: "speaker.wave.3",
                                  valueText: "\(Int((volume * 100).rounded()))%")
                }
            } header: {
                Text("Sounds")
            }

            if on {
                Section {
                    ForEach(Cue.allCases) { CueRow(cue: $0) }
                } header: {
                    Text("When an agent…")
                } footer: {
                    HStack {
                        Spacer()
                        Button("Restore Defaults") {
                            on = SettingDefault.soundsOn
                            volume = SettingDefault.soundVolume
                            for cue in Cue.allCases { UserDefaults.standard.removeObject(forKey: SettingKey.sound(cue)) }
                        }
                    }
                    .padding(.top, 8)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One kind of moment: a switch, a button to hear it, and what it sounds like.
private struct CueRow: View {
    let cue: Cue
    @AppStorage private var enabled: Bool

    init(cue: Cue) {
        self.cue = cue
        _enabled = AppStorage(wrappedValue: SettingDefault.sound, SettingKey.sound(cue))
    }

    var body: some View {
        SettingRow(explainer: cue.explainer) {
            HStack {
                Text(cue.label)
                Button {
                    Sounds.play(cue, preview: true)
                } label: {
                    Image(systemName: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Play this sound")
                Spacer()
                Toggle(cue.label, isOn: $enabled).labelsHidden()
            }
        }
    }
}

/// Push-to-talk dictation. Off by default; turning it off stops everything, and the models can be deleted here.
struct VoiceSettings: View {
    @AppStorage(SettingKey.voiceOn) private var on = SettingDefault.voiceOn
    @AppStorage(SettingKey.voiceEngine) private var engine = SettingDefault.voiceEngine
    @AppStorage(SettingKey.voiceKey) private var key = SettingDefault.voiceKey
    @AppStorage(SettingKey.voiceHold) private var hold = SettingDefault.voiceHold
    @AppStorage(SettingKey.voiceLanguage) private var language = SettingDefault.voiceLanguage
    @AppStorage(SettingKey.voiceModel) private var modelID = SettingDefault.voiceModel
    @AppStorage(SettingKey.voiceVocabulary) private var vocabulary = SettingDefault.voiceVocabulary
    @State private var confirming: WhisperModel?
    @State private var mic = AVCaptureDevice.authorizationStatus(for: .audio)
    private var models: WhisperModels { WhisperModels.shared }

    private var keyChoice: VoiceKey { VoiceKey(rawValue: key) ?? .rightOption }
    private var model: WhisperModel { WhisperModel.all.first { $0.id == modelID } ?? WhisperModel.all[0] }
    private var usesWhisper: Bool { engine == VoiceEngine.whisper.rawValue }

    var body: some View {
        Form {
            Section {
                SettingRow(explainer: "Hold a key and talk; when you let go, what you said is typed into the terminal or text field you're in. Audio stays on this Mac and is never saved.") {
                    Toggle("Dictation", isOn: $on)
                }
                if on {
                    SettingRow(explainer: keyChoice.explainer) {
                        Picker("Key", selection: $key) {
                            ForEach(VoiceKey.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                    }
                    SettingRow(explainer: hold
                               ? "Talk while the key is down. Esc cancels."
                               : "Tap the key to start, tap it again to stop. Esc cancels.") {
                        Picker("Key works by", selection: $hold) {
                            Text("Holding it").tag(true)
                            Text("Tapping on and off").tag(false)
                        }
                    }
                    SettingRow(explainer: mic == .denied || mic == .restricted
                               ? "HiveMinds isn't allowed to use the microphone. Turn it on in Privacy & Security."
                               : mic == .authorized ? "Allowed." : "macOS asks the first time you press the key.") {
                        HStack {
                            Text("Microphone")
                            Spacer()
                            if mic == .denied || mic == .restricted {
                                Button("Open Privacy Settings") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                                }
                            } else {
                                Text(mic == .authorized ? "On" : "Not asked yet").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Dictation")
            } footer: {
                // Shown even with dictation off, so the downloads are always one click from gone.
                if models.installedBytes > 0 {
                    HStack {
                        Text("Whisper models use \(ByteCountFormatter.string(fromByteCount: models.installedBytes, countStyle: .file)).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove Whisper Models", role: .destructive) { models.removeAll() }
                    }
                    .padding(.top, 8)
                }
            }

            if on {
                Section {
                    SettingRow(explainer: (VoiceEngine(rawValue: engine) ?? .apple).explainer) {
                        Picker("Speech engine", selection: $engine) {
                            ForEach(VoiceEngine.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                    }
                    if usesWhisper { whisperModelRow }
                    SettingRow(explainer: usesWhisper && model.englishOnly && language != "en" && language != "auto"
                               ? "This model only knows English. Pick \"Base, many languages\" to dictate in another language."
                               : "The language you speak.") {
                        Picker("Language", selection: $language) {
                            ForEach(VoiceLanguage.choices, id: \.code) { Text($0.label).tag($0.code) }
                        }
                    }
                    SettingRow(explainer: "Names and jargon it should expect, separated by commas, e.g. SwiftUI, HiveMinds, Store.swift.") {
                        TextField("Words to listen for", text: $vocabulary, prompt: Text("None"))
                    }
                } header: {
                    Text("Speech")
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: on, initial: true) { _, _ in
            Dictation.shared.refresh()
            mic = AVCaptureDevice.authorizationStatus(for: .audio)
        }
        .onChange(of: engine) { _, new in if new != VoiceEngine.whisper.rawValue { WhisperHelper.shared.stop() } }
        .confirmationDialog("Download the \(confirming?.label ?? "") model?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            Button("Download \(confirming?.megabytes ?? 0) MB") { if let m = confirming { models.download(m) } }
        } message: {
            Text("It comes from huggingface.co/ggerganov/whisper.cpp and is checked against a known checksum. It's saved in Application Support/HiveMinds/Voice, and you can remove it here any time.")
        }
    }

    @ViewBuilder private var whisperModelRow: some View {
        let progress = models.progress[model.id]
        SettingRow(explainer: WhisperModels.helper == nil
                   ? "This copy of HiveMinds was built without the Whisper helper. Rebuild with scripts/build-app.sh to use Whisper."
                   : models.failure[model.id]
                   ?? (models.isInstalled(model) ? "Downloaded. Runs on this Mac only." : "\(model.megabytes) MB, downloaded once.")) {
            HStack {
                Picker("Model", selection: $modelID) {
                    ForEach(WhisperModel.all) { Text($0.label).tag($0.id) }
                }
                if let progress {
                    ProgressView(value: progress).frame(width: 80)
                    Button("Cancel") { models.cancel(model) }
                } else if models.isInstalled(model) {
                    Button("Remove") { models.remove(model) }
                } else {
                    Button("Download…") { confirming = model }
                        .disabled(WhisperModels.helper == nil)
                }
            }
        }
    }
}

/// Where projects downloaded from GitHub are put.
struct ProjectSettings: View {
    @AppStorage(SettingKey.projectsFolder) private var folder = SettingDefault.projectsFolder

    var body: some View {
        Form {
            Section {
                SettingRow(explainer: folder.isEmpty
                           ? "Not chosen yet. HiveMinds asks the first time you add a project from GitHub."
                           : "Each project you add from GitHub is downloaded into its own folder here. Projects already added stay where they are.") {
                    HStack {
                        Text("Projects folder")
                        Spacer()
                        Text(folder.isEmpty ? "Ask when needed" : (folder as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(folder.isEmpty ? "Choose…" : "Change…") {
                            if let chosen = ProjectFolder.choose() { folder = chosen }
                        }
                    }
                }
            } header: {
                Text("Downloads from GitHub")
            } footer: {
                HStack {
                    Spacer()
                    if !folder.isEmpty {
                        Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) }
                    }
                    Button("Ask Next Time") { folder = SettingDefault.projectsFolder }
                        .disabled(folder.isEmpty)
                }
                .padding(.top, 8)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// How Claude Code and Codex sign in: through your plan, or with an API key billed per token.
struct AccountSettings: View {
    var body: some View {
        Form {
            ForEach(Provider.allCases) { ProviderSignIn(provider: $0) }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProviderSignIn: View {
    let provider: Provider
    @AppStorage private var signIn: String
    @State private var draft = ""
    @State private var hint: String?
    @State private var failed = false

    init(provider: Provider) {
        self.provider = provider
        _signIn = AppStorage(wrappedValue: SettingDefault.signIn, SettingKey.signIn(provider))
    }

    private var plan: String { provider == .claude ? "Claude plan" : "ChatGPT plan" }
    private var keySite: String { provider == .claude ? "console.anthropic.com" : "platform.openai.com" }
    private var keyPrompt: String { provider == .claude ? "sk-ant-…" : "sk-…" }

    var body: some View {
        Section {
            SettingRow(explainer: signIn == SignIn.apiKey.rawValue
                       ? "Agents are billed per token to your API account at \(keySite), not your \(plan)."
                       : "Agents use the account \(provider == .claude ? "claude" : "codex") is signed in to, and count toward your \(plan)'s limits.") {
                Picker("Sign in with", selection: $signIn) {
                    Text(plan).tag(SignIn.plan.rawValue)
                    Text("API key").tag(SignIn.apiKey.rawValue)
                }
            }
            if signIn == SignIn.apiKey.rawValue {
                if let hint {
                    SettingRow(explainer: "Kept in your Mac's Keychain. HiveMinds hands it only to the agents it starts.") {
                        HStack {
                            Text("API key")
                            Spacer()
                            Text("Saved \(hint)").foregroundStyle(.secondary).monospaced()
                            Button("Remove", role: .destructive) {
                                APIKeys.remove(provider)
                                self.hint = nil
                            }
                        }
                    }
                } else {
                    SettingRow(explainer: failed
                               ? "Couldn't save the key to the Keychain. Try again."
                               : "Paste a key from \(keySite). Until one is saved, agents keep using your \(plan).") {
                        HStack {
                            SecureField("API key", text: $draft, prompt: Text(keyPrompt))
                            Button("Save") {
                                failed = !APIKeys.set(draft, for: provider)
                                if !failed { draft = ""; hint = APIKeys.hint(provider) }
                            }
                            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        } header: {
            Text(provider.label)
        } footer: {
            if provider == Provider.allCases.last {
                Text("Changes apply to agents when they start or restart. Agents already running keep how they signed in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { if signIn == SignIn.apiKey.rawValue { hint = APIKeys.hint(provider) } }
        .onChange(of: signIn) { _, new in if new == SignIn.apiKey.rawValue { hint = APIKeys.hint(provider) } }
    }
}

/// A control with a one-line explanation below it.
struct SettingRow<Control: View>: View {
    let explainer: String
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            Text(explainer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }
}

/// A labelled slider with its current value on the right and a one-line explanation below.
struct SettingSlider: View {
    let title: String
    let explainer: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let lowIcon: String
    let highIcon: String
    let valueText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(valueText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range) {
                Text(title)
            } minimumValueLabel: {
                Image(systemName: lowIcon).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Image(systemName: highIcon).foregroundStyle(.secondary)
            }
            .labelsHidden()
            Text(explainer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
