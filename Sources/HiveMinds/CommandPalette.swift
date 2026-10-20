import SwiftUI

/// One thing the palette can do: go somewhere, or run an action.
struct PaletteItem: Identifiable {
    let id: String
    let title: String
    var subtitle = ""
    let icon: String
    let run: () -> Void
}

/// ⌘P: type a few letters to jump to any project, agent, tab or meeting, or run a common action.
/// ↑ and ↓ move, Return runs, Esc closes.
struct CommandPalette: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let results = matches
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a project, agent, tab or meeting…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(results) }
                    .onKeyPress(.downArrow) { move(1, results.count); return .handled }
                    .onKeyPress(.upArrow) { move(-1, results.count); return .handled }
                    .onKeyPress(.escape) { close(); return .handled }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            if !results.isEmpty {
                Divider().overlay(Theme.hairline)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, item in
                                row(item, selected: i == highlighted)
                                    .id(i)
                                    .onTapGesture { highlighted = i; run(results) }
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: highlighted) { _, i in proxy.scrollTo(i) }
                }
            } else if !query.isEmpty {
                Divider().overlay(Theme.hairline)
                Text("Nothing matches \"\(query)\".")
                    .foregroundStyle(.secondary)
                    .padding(16)
            }
        }
        .frame(width: 560)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: .rect(cornerRadius: 16))
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
    }

    private func row(_ item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(item.title).lineLimit(1)
            Spacer(minLength: 8)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(selected ? Color.white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func move(_ by: Int, _ count: Int) {
        guard count > 0 else { return }
        highlighted = (highlighted + by + count) % count
    }

    private func run(_ results: [PaletteItem]) {
        guard results.indices.contains(highlighted) else { return }
        let item = results[highlighted]
        close()
        item.run()
    }

    private func close() {
        store.showingPalette = false
    }

    /// Every word typed has to appear somewhere in the item. Titles that start with the query come first.
    private var matches: [PaletteItem] {
        let all = items
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return all }
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let found = all.filter { item in
            let hay = (item.title + " " + item.subtitle).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return found.filter { $0.title.lowercased().hasPrefix(q) } + found.filter { !$0.title.lowercased().hasPrefix(q) }
    }

    private var items: [PaletteItem] {
        var out: [PaletteItem] = []
        let current = store.currentProjectID

        // Actions first, so an empty palette shows what it can do.
        if let a = store.waitingAgents.first {
            out.append(PaletteItem(id: "a.waiting", title: "Go to Agent Who Needs You", subtitle: a.title, icon: "bell.badge") { store.jumpToWaiting() })
        }
        out.append(PaletteItem(id: "a.agent", title: "New Agent", subtitle: "⌘N", icon: "plus") { store.beginNewAgent(in: nil) })
        if !store.shownProjects.isEmpty {
            out.append(PaletteItem(id: "a.meeting", title: "New Meeting", subtitle: "⇧⌘N", icon: "bubble.left.and.bubble.right") { store.beginNewMeeting() })
        }
        if let current {
            out.append(PaletteItem(id: "a.browser", title: "New Browser Tab", subtitle: "⌘T", icon: "globe") { store.newBrowserTab(in: current) })
            out.append(PaletteItem(id: "a.shell", title: "New Shell Tab", subtitle: "⇧⌘T", icon: "terminal") { store.newShellTab(in: current) })
        }
        if case .agent(let id)? = store.selection, let agent = store.agent(id), store.canShowChanges(agent) {
            out.append(PaletteItem(id: "a.changes", title: "Show Changes", subtitle: agent.title, icon: "plusminus") { store.showingChanges = agent })
        }
        out.append(PaletteItem(id: "a.overview", title: "Overview", subtitle: "⌘0", icon: "square.grid.2x2") {
            store.mode = .agents
            store.selection = .overview
        })
        out.append(PaletteItem(id: "a.history", title: "History", subtitle: "⌘Y", icon: "clock.arrow.circlepath") {
            store.mode = .agents
            store.selection = .history
        })
        out.append(PaletteItem(id: "a.settings", title: "Settings", subtitle: "⌘,", icon: "gearshape") { openSettings() })

        // Places, the open project's first.
        let projects = store.shownProjects.sorted { ($0.id == current ? 0 : 1) < ($1.id == current ? 0 : 1) }
        for p in projects {
            out.append(PaletteItem(id: "p.\(p.id)", title: p.name, subtitle: "Canvas", icon: "folder") {
                store.mode = .agents
                store.selection = .project(p.id)
            })
            for a in store.agents(in: p) {
                out.append(PaletteItem(id: "g.\(a.id)", title: a.title, subtitle: "\(p.name) · \(store.state(a.id).status.label)", icon: "person") {
                    store.select(a.id)
                })
            }
            for t in store.browserTabs(in: p) {
                let title = Browsers.existing(t.id)?.title ?? t.title
                out.append(PaletteItem(id: "b.\(t.id)", title: title.isEmpty ? (URL(string: t.url)?.host() ?? "New tab") : title,
                                       subtitle: "\(p.name) · Browser", icon: "globe") {
                    store.mode = .agents
                    store.selection = .browser(t.id)
                })
            }
            for t in store.shellTabs(in: p) {
                let title = Shells.shared.existing(t.id)?.title ?? ""
                out.append(PaletteItem(id: "s.\(t.id)", title: title.isEmpty ? "Shell" : title, subtitle: "\(p.name) · Shell", icon: "terminal") {
                    store.mode = .agents
                    store.selection = .shell(t.id)
                })
            }
            for m in store.meetings where m.projectID == p.id {
                out.append(PaletteItem(id: "m.\(m.id)", title: m.title, subtitle: "\(p.name) · Meeting", icon: m.pattern.symbol) {
                    store.openMeeting(m.id)
                })
            }
        }
        return out
    }
}
