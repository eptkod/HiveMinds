import SwiftUI
import AppKit

@main
struct HiveMindsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        Window("HiveMinds", id: "main") {
            RootView()
                .environment(store)
                .frame(minWidth: 920, minHeight: 580)
                .preferredColorScheme(.dark)
                .modifier(WindowAppearance())
                .focusedSceneValue(\.isMainWindow, true)
        }
        .defaultSize(width: 1260, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Agent") { store.beginNewAgent(in: nil) }
                    .keyboardShortcut("n")
                Button("New Meeting…") { store.beginNewMeeting() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.projects.isEmpty)
                Button("New Browser Tab") { if let id = store.currentProjectID { store.newBrowserTab(in: id) } }
                    .keyboardShortcut("t")
                    .disabled(store.currentProjectID == nil)
                Button("Add Project Folder…") { store.chooseLocalFolder() }
                    .keyboardShortcut("o")
            }
            CloseTabCommand(store: store)
            CommandMenu("Agents") {
                Button("Go to Agent Who Needs You") { store.jumpToWaiting() }
                    .keyboardShortcut("j")
                    .disabled(store.waitingAgents.isEmpty)
                Button("Overview") { store.mode = .agents; store.selection = .overview }
                    .keyboardShortcut("0")
                Button("Canvas for This Project") {
                    if let id = store.currentProjectID { store.mode = .agents; store.selection = .project(id) }
                }
                .keyboardShortcut("g")
                .disabled(store.currentProjectID == nil)
            }
        }

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

/// ⌘W closes the open tab when the main window is in front, instead of closing the window (which quit the app).
/// Other windows, like Settings, still close as usual.
struct CloseTabCommand: Commands {
    let store: AppStore
    @FocusedValue(\.isMainWindow) private var isMainWindow

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(isMainWindow == true ? "Close Tab" : "Close") {
                if isMainWindow == true { store.closeCurrentTab() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
        }
    }
}

/// Set by the main window so the Close command knows it's in front. Written out by hand: `@Entry` needs Xcode.
private struct IsMainWindowKey: FocusedValueKey { typealias Value = Bool }

extension FocusedValues {
    var isMainWindow: Bool? {
        get { self[IsMainWindowKey.self] }
        set { self[IsMainWindowKey.self] = newValue }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets `swift run` behave like a real app (Dock icon, focus) as well as the built .app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
