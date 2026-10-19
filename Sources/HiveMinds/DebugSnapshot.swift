#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: `HIVEMINDS_SNAPSHOT=/path/prefix` saves PNGs of the window in each section,
/// so layouts can be checked without screen-recording permission.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(store: AppStore) {
        if ProcessInfo.processInfo.environment["HIVEMINDS_TEST_CREATE"] != nil, let p = store.projects.first {
            Task {
                do {
                    try await store.createAgent(projectID: p.id, provider: .claude, model: "haiku",
                                                role: "", task: "", ownBranch: true)
                    print("CREATE-OK", store.agents.last?.cwd ?? "", store.agents.last?.branch ?? "")
                } catch { print("CREATE-FAIL", error.localizedDescription) }
                exit(0)
            }
            return
        }
        if let path = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_MEETING"] {
            runTestMeeting(store: store, path: path)
            return
        }
        guard let prefix = ProcessInfo.processInfo.environment["HIVEMINDS_SNAPSHOT"] else { return }
        var steps: [(String, () -> Void)] = [
            ("overview", { store.mode = .agents; store.selection = .overview }),
            ("github", { store.mode = .github }),
            ("meetings", { store.mode = .meetings }),
            ("newagent", { store.mode = .agents; store.selection = .overview; store.beginNewAgent(in: nil) }),
        ]
        steps.append(("settings", { store.showingNewAgent = false; if let menu = NSApp.mainMenu?.items.first?.submenu,
               let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) { menu.performActionForItem(at: i) } }))
        steps.append(("settings-agents", { UserDefaults.standard.set("agents", forKey: SettingKey.settingsTab) }))
        if let m = store.meetings.last {
            steps.append(("meeting-room", { store.showingNewAgent = false; store.openMeeting(m.id) }))
            if m.status == .finished { steps.append(("meeting-outcome", { store.meetingTab = .outcome })) }
        }
        if let a = store.agents.first {
            steps.append(("agent", { store.showingNewAgent = false; store.select(a.id) }))
        }
        if let p = store.agents.first.flatMap({ store.project($0.projectID) }) ?? store.projects.first {
            steps.append(("workspace", { store.showingNewAgent = false; store.selection = .project(p.id) }))
            steps.append(("browser", { store.newBrowserTab(in: p.id, url: "https://example.com") }))
            steps.append(("canvas", { store.selection = .project(p.id) }))
        }
        if let m = store.meetings.first {
            steps.append(("meeting-tab", { store.showingNewAgent = false; store.mode = .agents; store.selection = .meeting(m.id) }))
        }
        // `HIVEMINDS_SNAPSHOT_ONLY=canvas,meeting-tab` takes just those.
        if let only = ProcessInfo.processInfo.environment["HIVEMINDS_SNAPSHOT_ONLY"]?.split(separator: ",").map(String.init) {
            steps = steps.filter { only.contains($0.0) }
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            for (name, apply) in steps {
                print("SNAP", name); fflush(stdout)
                apply()
                try? await Task.sleep(for: .seconds(name == "agent" ? 12 : 2.5))
                for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name)-\(i).png"))
                }
            }
            // The window capture above can't draw the see-through background, so the Overview's charts are
            // also drawn straight to an image on black. `HIVEMINDS_SNAPSHOT_ONLY=overview-stats` takes just this.
            if ProcessInfo.processInfo.environment["HIVEMINDS_SNAPSHOT_ONLY"].map({ $0.contains("overview-stats") }) ?? true {
                let h = store.spend.allHistory
                print("SNAP overview-stats", "agents:", store.agents.count, "days:", h.days.count, "tokens:", h.days.values.reduce(0) { $0 + $1.tokens }); fflush(stdout)
                let renderer = ImageRenderer(content: OverviewStats().environment(store).padding(32)
                    .frame(width: 1100).background(.black).environment(\.colorScheme, .dark))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(prefix)-overview-stats.png"))
                }
            }
            for w in NSApp.windows where w.isVisible {
                print("WINDOW", w.title, "opaque:", w.isOpaque, "blur-call-ok:", WindowBlur.set(w, radius: 24))
            }
            if ProcessInfo.processInfo.environment["HIVEMINDS_SNAPSHOT_QUIT"] != nil { exit(0) }
        }
    }

    /// `HIVEMINDS_TEST_MEETING=/path/to/repo` runs a short Haiku debate there and prints its progress.
    /// `HIVEMINDS_TEST_PATTERN` picks another format.
    private static func runTestMeeting(store: AppStore, path: String) {
        let env = ProcessInfo.processInfo.environment
        let pattern = env["HIVEMINDS_TEST_PATTERN"].flatMap(MeetingPattern.init) ?? .debate
        let project = store.addProject(path: path, repo: nil)
        Task {
            do {
                try await store.startMeeting(projectID: project.id, pattern: pattern,
                                             topic: "Should this tiny repo's greeting script be written in Python or Bash? Keep every note under 80 words.",
                                             seats: 2, rounds: 1, prNumber: nil, model: "haiku")
            } catch {
                print("MEETING-FAIL", error.localizedDescription); fflush(stdout); exit(1)
            }
            guard let id = store.meetings.last?.id else { exit(1) }
            if env["HIVEMINDS_TEST_TRUST"] != nil {
                // Answers Claude Code's "trust this folder?" for a scratch repo: down to "Yes", then Return.
                Task {
                    for _ in 0..<6 {
                        try? await Task.sleep(for: .seconds(6))
                        for seat in store.meeting(id)?.seats ?? [] where store.state(seat.agentID).status == .starting {
                            Terminals.shared.sendKeys(seat.agentID, "\u{1b}[B")
                            try? await Task.sleep(for: .milliseconds(300))
                            Terminals.shared.sendKeys(seat.agentID, "\r")
                        }
                    }
                }
            }
            var last = ""
            for _ in 0..<240 {
                try? await Task.sleep(for: .seconds(3))
                guard let m = store.meeting(id) else { exit(1) }
                let seats = m.seats.map { "\($0.name)=\(m.turns[$0.agentID]?.rawValue ?? "-")/\(store.state($0.agentID).status.rawValue)" }
                let line = "MEETING \(m.status.rawValue) \(meetingProgress(m)) \(seats.joined(separator: " ")) \(meetingSpend(m))"
                if line != last { print(line); fflush(stdout); last = line }
                if m.status == .finished {
                    try? await Task.sleep(for: .seconds(5))
                    let m = store.meeting(id)!
                    print("MEETING-DONE", m.outputURL.path, m.commit ?? "no-commit", meetingSpend(m), m.totalTokens, m.note ?? ""); fflush(stdout)
                    if env["HIVEMINDS_TEST_KEEP"] == nil { exit(0) }
                    return
                }
            }
            print("MEETING-TIMEOUT"); fflush(stdout); exit(2)
        }
    }
}
#endif
