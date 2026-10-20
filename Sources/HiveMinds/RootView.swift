import SwiftUI

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if let warning = store.warning {
                        NoticeBar(text: warning, icon: "exclamationmark.triangle", tint: .orange) { store.warning = nil }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let notice = store.notice {
                        NoticeBar(text: notice) { store.notice = nil }
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(Motion.bouncy, value: store.notice)
                .animation(Motion.bouncy, value: store.warning)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModeSwitcher(mode: $store.mode)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if !store.waitingAgents.isEmpty {
                    Button { store.jumpToWaiting() } label: {
                        Label("\(store.waitingAgents.count) needs you", systemImage: "bell.badge")
                    }
                    .tint(.orange)
                    .help("Go to the agent who's waiting (⌘J)")
                }
                if store.mode == .meetings {
                    Button { store.beginNewMeeting() } label: {
                        Label("New Meeting", systemImage: "plus")
                    }
                    .help("New Meeting (⇧⌘N)")
                    .disabled(store.projects.isEmpty)
                } else {
                    Button { store.beginNewAgent(in: nil) } label: {
                        Label("New Agent", systemImage: "plus")
                    }
                    .help("New Agent (⌘N)")
                }
            }
        }
        .overlay(alignment: .top) {
            if store.showingPalette {
                ZStack(alignment: .top) {
                    // Clicking anywhere else closes it.
                    Color.black.opacity(0.001)
                        .onTapGesture { store.showingPalette = false }
                    CommandPalette()
                        .padding(.top, 70)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .animation(Motion.press, value: store.showingPalette)
        .sheet(item: $store.showingChanges) { ChangesSheet(agent: $0) }
        .confirmationDialog("Restart \(store.pendingRestart.map { "\"\($0.agent.title)\" \($0.what)" } ?? "the agent")?",
                            isPresented: Binding(get: { store.pendingRestart != nil }, set: { if !$0 { store.pendingRestart = nil } }),
                            presenting: store.pendingRestart) { r in
            Button("Restart Agent") { store.confirmRestart(r) }
        } message: { r in
            Text(r.agent.provider == .claude
                 ? "This restarts the agent. Claude Code picks up the same conversation."
                 : "This restarts the agent. Codex starts a new conversation, so it won't remember this one.")
        }
        .sheet(isPresented: $store.showingNewAgent) { NewAgentSheet() }
        .sheet(isPresented: $store.showingNewMeeting) { NewMeetingSheet() }
        .confirmationDialog("Delete \(store.pendingDelete.map { "\"\($0.title)\"" } ?? "agent")?",
                            isPresented: Binding(get: { store.pendingDelete != nil }, set: { if !$0 { store.pendingDelete = nil } }),
                            presenting: store.pendingDelete) { agent in
            Button("Delete Agent", role: .destructive) { Task { await store.deleteAgent(agent) } }
        } message: { agent in
            Text(agent.branch != nil
                 ? "Its session stops. Its branch \(agent.branch!) and any commits on it are kept. Its folder is removed only if nothing is left uncommitted."
                 : "Its session stops. Files in the project are not touched.")
        }
        .alert("Something went wrong",
               isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .task {
            #if DEBUG
            print("BOOT start"); fflush(stdout)
            #endif
            await store.bootstrap()
            #if DEBUG
            DebugSnapshot.runIfRequested(store: store)
            #endif
        }
    }

    @ViewBuilder private var detail: some View {
        if store.toolsChecked && store.tools.providers.isEmpty {
            SetupView()
        } else {
            Group {
                switch store.mode {
                case .agents:
                    if let id = store.currentProjectID, let project = store.project(id) {
                        WorkspaceView(project: project)
                    } else if store.selection == .history {
                        HistoryView()
                    } else {
                        OverviewView()
                    }
                case .meetings:
                    MeetingsView()
                case .github:
                    GitHubView()
                }
            }
            .transition(Motion.enter)
            .animation(Motion.bouncy, value: store.mode)
        }
    }
}

struct SetupView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text("Install Claude Code to get started").font(.title2.weight(.semibold))
            Text("HiveMinds runs your agents with the Claude Code app on this Mac, using your own Claude plan. Paste this into Terminal, then sign in when it asks.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Text("curl -fsSL https://claude.ai/install.sh | bash")
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            Button("Check Again") { Task { await store.recheckTools() } }
                .buttonStyle(.glassProminent)
        }
        .padding(40)
    }
}

/// The Agents / Meetings / GitHub switch in the toolbar. The chosen section sits on a solid white pill
/// that slides between choices; the others stay as plain text. The toolbar supplies the glass around it.
struct ModeSwitcher: View {
    @Binding var mode: Mode
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Mode.allCases) { item in
                let selected = item == mode
                Button {
                    withAnimation(Motion.bouncy) { mode = item }
                } label: {
                    Text(item.rawValue)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(selected ? Color.black : Color.secondary)
                        .padding(.horizontal, 14)
                        // Tall enough that the pill fills the toolbar's glass with the same 3pt inset on every side.
                        .padding(.vertical, 8)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Color.white)
                                    .matchedGeometryEffect(id: "mode", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.squish)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .fixedSize()
    }
}
