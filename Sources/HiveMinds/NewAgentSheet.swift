import AppKit
import SwiftUI

/// One question up front (what should it work on?). Everything else has a sensible default and sits under Options.
struct NewAgentSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var projectID: UUID?
    /// Whether the sheet was opened for a specific project, so it shouldn't ask which one.
    @State private var projectGiven = false
    @State private var provider: Provider = .claude
    @State private var model = "default"
    @State private var effort = Effort.medium
    @State private var ownBranch = true
    @State private var access = Access.auto
    @State private var role = ""
    @State private var task = ""
    @State private var attachments: [Attachment] = []
    @State private var dropTargeted = false
    @State private var pasteMonitor: Any?
    @State private var showOptions = false
    @State private var error: String?
    @State private var working = false

    private var project: Project? { projectID.flatMap { store.project($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.shownProjects.isEmpty {
                Text("New Agent").font(.title2.weight(.semibold)).padding([.horizontal, .top], 24)
                noProjects
            } else {
                form
            }
        }
        .frame(width: 480)
        .onAppear {
            projectGiven = store.newAgentProject != nil
            projectID = store.newAgentProject ?? store.shownProjects.first?.id
            let available = store.tools.providers
            provider = available.contains(AgentDefaults.provider) ? AgentDefaults.provider : (available.first ?? .claude)
            model = provider == .claude ? AgentDefaults.model : "default"
            effort = AgentDefaults.effort
            access = AgentDefaults.access
            role = AgentDefaults.role
            ownBranch = AgentDefaults.ownBranch && (project?.isGitRepo ?? false)
            // ⌘V with a screenshot or copied files attaches them. Text pastes go through as normal.
            pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                      event.charactersIgnoringModifiers == "v" else { return event }
                let found = Attachment.from(pasteboard: .general)
                guard !found.isEmpty else { return event }
                add(found)
                return nil
            }
        }
        .onDisappear {
            if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
            pasteMonitor = nil
        }
    }

    private func add(_ items: [Attachment]) {
        withAnimation(Motion.bouncy) { attachments += items }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "Pick files or screenshots for the agent to look at."
        if panel.runModal() == .OK { add(panel.urls.map { Attachment(file: $0) }) }
    }

    private var noProjects: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Agents work inside a project. Add one first.").foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Add a Folder…") { dismiss(); store.chooseLocalFolder() }
                Button("Add from GitHub") { dismiss(); store.mode = .github }
                    .buttonStyle(.glassProminent)
            }
        }
        .padding(24)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("New Agent").font(.title2.weight(.semibold))
                if projectGiven, let project {
                    Text("in \(project.name)").foregroundStyle(.secondary)
                }
                Spacer()
                if !projectGiven {
                    Picker("Project", selection: $projectID) {
                        ForEach(store.shownProjects) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: projectID) { _, _ in ownBranch = AgentDefaults.ownBranch && (project?.isGitRepo ?? false) }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("What should it work on?", text: $task, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(4...10)
                if !attachments.isEmpty { AttachmentStrip(items: $attachments) }
                HStack {
                    Button(action: chooseFiles) {
                        Image(systemName: "paperclip").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.squish)
                    .help("Attach files or screenshots")
                    if attachments.isEmpty {
                        Text("Paste or drop screenshots and files here")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
            .padding(12)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Theme.hairline, lineWidth: dropTargeted ? 1.5 : 0.5))
            .animation(Motion.press, value: dropTargeted)
            .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
                Attachment.load(providers) { add([$0]) }
                return true
            }

            DisclosureGroup(isExpanded: $showOptions) {
                options.padding(.top, 8)
            } label: {
                // The whole row toggles, not just the chevron.
                Button {
                    withAnimation(Motion.bouncy) { showOptions.toggle() }
                } label: {
                    Text("Options")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.secondary)

            if access == .unrestricted {
                Label(Access.unrestricted.explainer, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(working ? "Starting…" : "Start") { create() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(working || projectID == nil)
            }
        }
        .padding(24)
    }

    private var options: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            if store.tools.providers.count > 1 {
                GridRow {
                    Text("Runs on")
                    Picker("Runs on", selection: $provider) {
                        ForEach(store.tools.providers) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: provider) { _, p in model = p == .claude ? AgentDefaults.model : "default" }
                }
            }
            if provider.models.count > 1 {
                GridRow {
                    Text("Model")
                    Picker("Model", selection: $model) {
                        ForEach(provider.models, id: \.self) { Text($0 == "default" ? "Default" : $0.capitalized).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            GridRow {
                Text("Effort")
                Picker("Effort", selection: $effort) {
                    ForEach(Effort.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help("How hard it thinks before answering. Higher is slower and uses more of your plan.")
            }
            GridRow {
                Text("Access")
                Picker("Access", selection: $access) {
                    ForEach(Access.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .help(access.explainer)
            }
            if project?.isGitRepo ?? false {
                GridRow {
                    Text("Own branch")
                    Toggle("Own branch", isOn: $ownBranch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("Keeps its changes separate, so you can review them as a pull request.")
                }
            }
            if provider == .claude {
                GridRow(alignment: .firstTextBaseline) {
                    Text("Role")
                    TextField("Role", text: $role, prompt: Text("e.g. careful reviewer who writes tests first"))
                        .labelsHidden()
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private func create() {
        guard let projectID else { return }
        working = true
        error = nil
        Task {
            do {
                try await store.createAgent(projectID: projectID, provider: provider, model: model, effort: effort,
                                            access: access, role: role, task: task, attachments: attachments, ownBranch: ownBranch && (project?.isGitRepo ?? false))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
