import SwiftUI
import AppKit

/// Everything you can do to an agent, in one menu. The sidebar row, its tab and its tile all show this same menu.
struct AgentMenu: View {
    @Environment(AppStore.self) private var store
    let agent: Agent

    var body: some View {
        Button("Show Changes…") { store.showingChanges = agent }
            .disabled(!store.canShowChanges(agent))
        Divider()
        Button("Restart") { store.restart(agent.id) }
        Menu("Restart With") { RestartWith(agent: agent) }
            .disabled(!store.canRestartWith(agent))
        Button("Stop") { store.stop(agent.id) }
        Divider()
        Button("Show in Finder") { store.revealInFinder(agent.cwd) }
        OpenInMenu(path: agent.cwd)
        Button("Copy Folder Path") { copyToClipboard(agent.cwd) }
        if let branch = agent.branch {
            Button("Copy Branch Name") { copyToClipboard(branch) }
        }
        Divider()
        Button(store.picked.contains(agent.id) ? "Deselect" : "Select") { store.togglePick(agent.id) }
        if store.picked.count > 1 && store.picked.contains(agent.id) {
            Button("Delete \(store.picked.count) Selected Agents…", role: .destructive) { store.deletePicked() }
        } else {
            Button("Delete Agent…", role: .destructive) { store.pendingDelete = agent }
        }
    }
}

/// The installed editors, each opening the folder. Editors that aren't installed don't show.
struct OpenInMenu: View {
    let path: String

    var body: some View {
        let editors = Editor.installed
        if !editors.isEmpty {
            Menu("Open In") {
                ForEach(editors) { e in
                    Button(e.name) { e.open(path) }
                }
            }
        }
    }
}

extension AgentMenu {
/// Picks a new access level or model. Each restarts the agent, after asking.
struct RestartWith: View {
    @Environment(AppStore.self) private var store
    let agent: Agent

    var body: some View {
        Section("Access") {
            ForEach(Access.allCases) { a in
                Button(a.label) { store.pendingRestart = PendingRestart(agent: agent, access: a) }
                    .disabled(a == agent.access)
            }
        }
        if agent.provider.models.count > 1 {
            Section("Model") {
                ForEach(agent.provider.models, id: \.self) { m in
                    Button(m == "default" ? "Default" : m.capitalized) { store.pendingRestart = PendingRestart(agent: agent, model: m) }
                        .disabled(m == agent.model)
                }
            }
        }
    }
}
}

/// A change to an agent's launch settings, waiting for you to confirm the restart it needs.
struct PendingRestart: Identifiable {
    let id = UUID()
    var agent: Agent
    var access: Access?
    var model: String?

    var what: String {
        if let access { return "with \(access.label)" }
        if let model { return "on \(model == "default" ? "the default model" : model.capitalized)" }
        return ""
    }
}

extension AppStore {
    /// Changes are read with git, so the agent has to work in a git project.
    func canShowChanges(_ agent: Agent) -> Bool {
        tools.git != nil && (agent.branch != nil || project(agent.projectID)?.isGitRepo == true)
    }

    /// Only an agent that isn't busy or waiting on you can be restarted with new settings, so no turn is cut off.
    func canRestartWith(_ agent: Agent) -> Bool {
        switch state(agent.id).status {
        case .idle, .done, .asleep: true
        case .working, .needsYou, .starting: false
        }
    }

    func confirmRestart(_ r: PendingRestart) {
        update(r.agent.id) { a in
            if let access = r.access { a.access = access }
            if let model = r.model { a.model = model }
        }
        restart(r.agent.id)
    }
}

func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// A code editor that can open a folder.
struct Editor: Identifiable {
    let name: String
    let bundleID: String
    var id: String { bundleID }

    private static let known = [
        Editor(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        Editor(name: "Cursor", bundleID: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Windsurf", bundleID: "com.exafunction.windsurf"),
        Editor(name: "Zed", bundleID: "dev.zed.Zed"),
        Editor(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        Editor(name: "Nova", bundleID: "com.panic.Nova"),
        Editor(name: "BBEdit", bundleID: "com.barebones.bbedit"),
        Editor(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        Editor(name: "Terminal", bundleID: "com.apple.Terminal"),
        Editor(name: "iTerm", bundleID: "com.googlecode.iterm2"),
        Editor(name: "Ghostty", bundleID: "com.mitchellh.ghostty"),
    ]

    /// Looked up once; installing an editor shows after a relaunch.
    @MainActor static let installed: [Editor] = known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }

    @MainActor func open(_ path: String) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
