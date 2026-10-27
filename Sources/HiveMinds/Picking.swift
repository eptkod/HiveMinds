import SwiftUI
import AppKit

// Select mode: tick several agents on the Canvas, the Overview or in the sidebar, then delete them in one go.
// Turn it on with the Select button (Canvas tab row, Overview), or ⌘-click an agent anywhere.

extension AppStore {
    /// The agents select mode works on: the open project's, or every agent on the Overview.
    var pickScope: [Agent] {
        if let id = currentProjectID, let project = project(id) { return agents(in: project) }
        return workspaceAgents
    }

    /// Not working, starting or waiting on you, so nothing is cut off by deleting it.
    func isFinished(_ agent: Agent) -> Bool {
        switch state(agent.id).status {
        case .idle, .done, .asleep: true
        case .working, .needsYou, .starting: false
        }
    }

    func togglePick(_ id: UUID) {
        picking = true
        if picked.contains(id) { picked.remove(id) } else { picked.insert(id) }
    }

    func endPicking() {
        picking = false
        picked = []
    }

    /// Asks before deleting the ticked agents.
    func deletePicked() {
        let list = agents.filter { picked.contains($0.id) }
        if !list.isEmpty { pendingDeleteMany = list }
    }

    /// Asks before deleting every finished agent in a project.
    func deleteFinished(in project: Project) {
        let list = agents(in: project).filter(isFinished)
        if !list.isEmpty { pendingDeleteMany = list }
    }

    func deleteManyMessage(_ list: [Agent]) -> String {
        let busy = list.filter { !isFinished($0) }.count
        let warning = busy == 0 ? "" : "\(busy) of them \(busy == 1 ? "is" : "are") still working and will be stopped. "
        return warning + "Their sessions stop. Branches and commits are kept, and each folder is removed only if nothing is left uncommitted. You can bring them back from History."
    }

    /// A click on an agent: in select mode, or with ⌘ held, it ticks the agent instead of opening it.
    /// Returns true when it was taken as a tick.
    func pickOnClick(_ id: UUID) -> Bool {
        guard picking || NSEvent.modifierFlags.contains(.command) else { return false }
        togglePick(id)
        return true
    }
}

/// The bar along the bottom while select mode is on.
struct SelectionBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let scope = store.pickScope
        let finished = scope.filter(store.isFinished)
        HStack(spacing: 12) {
            Text(store.picked.isEmpty ? "Click agents to select them" : "\(store.picked.count) selected")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer(minLength: 8)
            Button("Select Finished") { store.picked = Set(finished.map(\.id)) }
                .disabled(finished.isEmpty)
                .help("Select the \(finished.count) agents here that aren't working or waiting on you")
            Button("Select All") { store.picked = Set(scope.map(\.id)) }
                .disabled(scope.isEmpty)
            Button("Clear") { store.picked = [] }
                .disabled(store.picked.isEmpty)
            Button(role: .destructive) { store.deletePicked() } label: {
                Text(store.picked.isEmpty ? "Delete…" : "Delete \(store.picked.count)…")
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .fixedSize()
            .disabled(store.picked.isEmpty)
            Button("Done") { store.endPicking() }
                .help("Leave select mode")
        }
        .buttonStyle(.glass)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .capsule)
        .frame(maxWidth: 720)
        .padding(14)
        .animation(Motion.press, value: store.picked.count)
    }
}

/// The round tick shown on an agent in select mode.
struct PickMark: View {
    let picked: Bool

    var body: some View {
        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(picked ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace))
    }
}

/// The Canvas tab row's and Overview's way into select mode.
struct SelectButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            if store.picking { store.endPicking() } else { store.picking = true }
        } label: {
            Image(systemName: store.picking ? "trash.fill" : "trash")
        }
        .buttonStyle(.borderless)
        .help(store.picking ? "Leave select mode" : "Select several agents to delete them at once (or ⌘-click an agent)")
    }
}

extension View {
    /// An accent ring around an agent that's ticked in select mode.
    func pickedRing(_ picked: Bool, cornerRadius: CGFloat) -> some View {
        overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(picked ? 0.9 : 0), lineWidth: 2))
            .animation(Motion.press, value: picked)
    }
}

/// Asks before deleting several agents at once.
struct DeleteManyDialog: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        let list = store.pendingDeleteMany ?? []
        let title = list.count == 1 ? "Delete 1 agent?" : "Delete \(list.count) agents?"
        content.confirmationDialog(title,
                                   isPresented: Binding(get: { store.pendingDeleteMany != nil }, set: { if !$0 { store.pendingDeleteMany = nil } }),
                                   presenting: store.pendingDeleteMany) { list in
            Button(list.count == 1 ? "Delete Agent" : "Delete \(list.count) Agents", role: .destructive) {
                Task { await store.deleteAgents(list) }
            }
        } message: { list in
            Text(store.deleteManyMessage(list))
        }
    }
}
