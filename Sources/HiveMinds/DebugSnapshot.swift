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
        if let path = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_ASK"] {
            runTestAsk(store: store, path: path)
            return
        }
        if let path = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_ISSUE"] {
            runTestIssue(store: store, path: path)
            return
        }
        guard let prefix = ProcessInfo.processInfo.environment["HIVEMINDS_SNAPSHOT"] else { return }
        var steps: [(String, () -> Void)] = [
            ("overview", { store.mode = .agents; store.selection = .overview }),
            ("github", { store.mode = .github; UserDefaults.standard.set("Repositories", forKey: SettingKey.githubTab) }),
            ("github-issues", { UserDefaults.standard.set("Issues", forKey: SettingKey.githubTab) }),
            ("github-repos", { UserDefaults.standard.set("Repositories", forKey: SettingKey.githubTab) }),
            ("meetings", { store.mode = .meetings }),
            ("history", { store.mode = .agents; store.selection = .history }),
            ("newagent", { store.mode = .agents; store.selection = .overview; store.beginNewAgent(in: nil) }),
        ]
        steps.append(("settings", { store.showingNewAgent = false; if let menu = NSApp.mainMenu?.items.first?.submenu,
               let i = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) { menu.performActionForItem(at: i) } }))
        steps.append(("settings-agents", { UserDefaults.standard.set("agents", forKey: SettingKey.settingsTab) }))
        // Shows the split-model rows, then puts the setting back as it was.
        let split = UserDefaults.standard.object(forKey: SettingKey.meetingSplitModels)
        steps.append(("settings-meetings", { UserDefaults.standard.set(true, forKey: SettingKey.meetingSplitModels)
            UserDefaults.standard.set("meetings", forKey: SettingKey.settingsTab) }))
        steps.append(("newmeeting", { store.mode = .meetings; store.beginNewMeeting() }))
        steps.append(("newmeeting-done", { store.showingNewMeeting = false
            UserDefaults.standard.set(split, forKey: SettingKey.meetingSplitModels) }))
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
            // The smallest window with tiles pinned one cell wide, the way they could be sized before tiles
            // had a smallest size: nothing should spill out of its card. Then the saved layout goes back.
            let savedPins = store.canvasPins[p.id]
            steps.append(("canvas-narrow", {
                NSApp.windows.first { $0.isVisible && $0.title == "HiveMinds" }?.setContentSize(NSSize(width: 920, height: 580))
                let pins = store.canvasItems(in: p).prefix(TilePin.columns).enumerated().map { i, id in
                    (id, TilePin(col: i, row: 0, width: 1, height: TilePin.rows))
                }
                store.pinCanvas(in: p, Dictionary(uniqueKeysWithValues: pins))
            }))
            steps.append(("canvas-narrow-done", {
                store.pinCanvas(in: p, savedPins ?? [:])
                NSApp.windows.first { $0.isVisible && $0.title == "HiveMinds" }?.setContentSize(NSSize(width: 1260, height: 820))
            }))
            steps.append(("shell", {
                store.newShellTab(in: p.id)
                if case .shell(let id) = store.selection {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Shells.shared.existing(id)?.view.send(txt: "pwd; echo $0\r") }
                }
            }))
            steps.append(("shell-canvas", { store.selection = .project(p.id) }))
            // Enough shells to spill onto more pages, then turn to the next page and the last (which should
            // fill its page), the way a sideways swipe would, and close them again.
            steps.append(("canvas-pages", { for _ in 0..<10 { store.newShellTab(in: p.id) }; store.selection = .project(p.id) }))
            func turnPage() {
                func find(_ v: NSView) -> PagerAnchor.View? { (v as? PagerAnchor.View) ?? v.subviews.lazy.compactMap(find).first }
                let pager = NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first
                print("SWIPE pages", pager?.pages ?? 0)
                pager?.turn(1)
            }
            steps.append(("canvas-page2", turnPage))
            steps.append(("canvas-page3", turnPage))
            steps.append(("canvas-cleanup", { for t in store.shellTabs(in: p).suffix(10) { store.closeShellTab(t.id) } }))
            steps.append(("shell-closed", { if let t = store.shellTabs(in: p).last { store.closeShellTab(t.id) } }))
        }
        if let m = store.meetings.first {
            steps.append(("meeting-tab", { store.showingNewAgent = false; store.mode = .agents; store.selection = .meeting(m.id) }))
        }
        steps.append(("palette", { store.showingNewAgent = false; store.mode = .agents; store.selection = .overview; store.showingPalette = true }))
        if let a = store.agents.first(where: { store.canShowChanges($0) }) {
            steps.append(("changes", { store.showingPalette = false; store.showingChanges = a }))
        }
        steps.append(("warning", { store.showingChanges = nil; store.warning = "\"Test agent\" has used about $10.42 at API prices (an estimate), past your $10.00 warning." }))
        // The Canvas mid-gesture: the first tile held part way across by its title bar, a few positions along,
        // then dropped; then its bottom-right corner dragged out and held, then let go. Synthetic mouse events
        // don't reach SwiftUI's gestures, so `TileGridDebug` runs the same steps a drag does.
        // Use a scratch `HIVEMINDS_SUPPORT_DIR`: the drop and resize are saved.
        if let p = store.projects.first {
            func hold(_ h: TileGridDebug.Hold?) { NotificationCenter.default.post(name: TileGridDebug.hold, object: h) }
            steps.append(("drag-move", { store.showingNewAgent = false; store.mode = .agents; store.selection = .project(p.id)
                for (i, t) in [0.1, 0.25, 0.45].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 0.4) { hold(.init(index: 0, by: CGSize(width: t, height: t * 0.6))) }
                }
            }))
            steps.append(("drag-dropped", { hold(nil) }))
            steps.append(("drag-resize", {
                for (i, t) in [0.08, 0.16, 0.24].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.4) { hold(.init(index: 0, by: CGSize(width: t, height: t), edges: [.bottom, .trailing])) }
                }
            }))
            steps.append(("drag-resized", { hold(nil) }))
            // A tile on the second page sized by its corner: it should move to the first page, where it stays.
            steps.append(("drag-page2", { store.showingNewAgent = false; store.mode = .agents; store.selection = .project(p.id)
                func find(_ v: NSView) -> PagerAnchor.View? { (v as? PagerAnchor.View) ?? v.subviews.lazy.compactMap(find).first }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first?.turn(1) }
                let last = store.canvasItems(in: p).count - 1
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { hold(.init(index: last, by: CGSize(width: -0.2, height: 0.2), edges: [.top, .leading])) }
            }))
            steps.append(("drag-page2-done", { hold(nil) }))
            // The first tile held at the right edge: after a moment the page turns and it lands on page 2.
            steps.append(("drag-edge", { store.showingNewAgent = false; store.mode = .agents; store.selection = .project(p.id)
                for (i, t) in [0.3, 0.6, 0.85].enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + Double(i) * 0.2) { hold(.init(index: 0, by: CGSize(width: t, height: 0.1))) }
                }
            }))
            steps.append(("drag-edge-dropped", { hold(nil) }))
            // Let go at the right edge straight away: it should still go to the next page.
            steps.append(("drag-edge-quick", { if let pager = { () -> PagerAnchor.View? in
                    func find(_ v: NSView) -> PagerAnchor.View? { (v as? PagerAnchor.View) ?? v.subviews.lazy.compactMap(find).first }
                    return NSApp.windows.lazy.compactMap { $0.contentView.flatMap(find) }.first }() { pager.turn(-5) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { hold(.init(index: 0, by: CGSize(width: 0.85, height: 0.1))) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { hold(nil) }
            }))
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

    /// `HIVEMINDS_TEST_ASK=/path/to/repo` starts a Haiku agent on Manual review there, then answers its
    /// permission prompt and a two-question AskUserQuestion the way the Canvas buttons do. It saves a
    /// window capture of each prompt on the Canvas to `HIVEMINDS_TEST_ASK_SNAP` (a path prefix), if set.
    private static func runTestAsk(store: AppStore, path: String) {
        let env = ProcessInfo.processInfo.environment
        let project = store.addProject(path: path, repo: nil)
        func log(_ s: String) { print(s); fflush(stdout) }
        func snap(_ name: String) {
            guard let prefix = env["HIVEMINDS_TEST_ASK_SNAP"], let window = NSApp.windows.first(where: \.isVisible),
                  let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
        }
        Task {
            do {
                try await store.createAgent(projectID: project.id, provider: .claude, model: "haiku", access: .manual, role: "",
                                            task: "Run this shell command with the Bash tool and nothing else: touch asked.txt", ownBranch: false)
            } catch { log("ASK-FAIL \(error.localizedDescription)"); exit(1) }
            guard let id = store.agents.last?.id else { exit(1) }
            store.selection = .project(project.id)
            @MainActor func wait(_ what: String, _ ok: @MainActor () -> Bool) async -> Bool {
                for _ in 0..<60 {
                    if ok() { return true }
                    // Answers "trust this folder?" for the scratch repo: down to "Yes", then Return.
                    if store.state(id).status == .starting {
                        Terminals.shared.sendKeys(id, "\u{1b}[B")
                        try? await Task.sleep(for: .milliseconds(300))
                        Terminals.shared.sendKeys(id, "\r")
                    }
                    try? await Task.sleep(for: .seconds(2))
                }
                log("ASK-TIMEOUT waiting for \(what): \(store.state(id).status.rawValue) \(store.state(id).activity)"); return false
            }
            guard await wait("permission", { if case .permission? = store.state(id).ask?.kind { true } else { false } }) else { exit(2) }
            if case .permission(let tool, let detail)? = store.state(id).ask?.kind { log("ASK-PERMISSION \(tool): \(detail)") }
            try? await Task.sleep(for: .seconds(1)); snap("permission")
            store.allow(id)
            let file = URL(fileURLWithPath: path).appendingPathComponent("asked.txt").path
            guard await wait("file", { FileManager.default.fileExists(atPath: file) }) else { exit(2) }
            log("ASK-ALLOWED file exists")
            guard await wait("stop", { store.state(id).status == .done }) else { exit(2) }
            store.sendInput(id, "Use the AskUserQuestion tool once with two questions: (1) favourite color, options red/green/blue; (2) favourite fruit, options apple/pear. Then reply with exactly: ANSWERS=<color>,<fruit>")
            guard await wait("questions", { if case .questions? = store.state(id).ask?.kind { true } else { false } }) else { exit(2) }
            if case .questions(let q)? = store.state(id).ask?.kind { log("ASK-QUESTIONS \(q.map { "\($0.question) \($0.options)" })") }
            try? await Task.sleep(for: .seconds(1)); snap("questions")
            store.answer(id, [.option(2), .text("a ripe mango")])
            guard await wait("answers", { store.state(id).status == .done }) else { exit(2) }
            try? await Task.sleep(for: .seconds(2))
            log("ASK-DONE \(store.state(id).activity)")
            if let a = store.agent(id) { await store.deleteAgent(a) }
            exit(0)
        }
    }

    /// `HIVEMINDS_TEST_ISSUE=/path/to/repo` starts a Haiku agent on a made-up issue in the background, the way
    /// the Issues view does, and checks it does the work on its own branch without being opened.
    private static func runTestIssue(store: AppStore, path: String) {
        let project = store.addProject(path: path, repo: "eptkod/HiveMinds")
        func log(_ s: String) { print(s); fflush(stdout) }
        let issue = GitHubModel.Issue(number: 999, title: "Add a done file", body: "Create a file named `done.txt` containing `ok`.",
                                      url: "https://github.com/eptkod/HiveMinds/issues/999", createdAt: Date(), updatedAt: Date(),
                                      author: nil, labels: [], repo: "eptkod/HiveMinds")
        Task {
            do {
                try await store.createAgent(projectID: project.id, provider: .claude, model: "haiku", access: .unrestricted, role: "",
                                            task: AppStore.issuePrompt(issue, note: "Don't touch any other file."), ownBranch: true,
                                            issue: issue.ref(), open: false)
            } catch { log("ISSUE-FAIL \(error.localizedDescription)"); exit(1) }
            guard let a = store.agents.last else { exit(1) }
            log("ISSUE-STARTED branch=\(a.branch ?? "-") title=\(a.title) issue=\(a.issue?.number ?? 0) running=\(Terminals.shared.isRunning(a.id)) mode=\(store.mode.rawValue)")
            let file = URL(fileURLWithPath: a.cwd).appendingPathComponent("done.txt").path
            for _ in 0..<60 {
                if store.state(a.id).status == .starting {
                    Terminals.shared.sendKeys(a.id, "\u{1b}[B")
                    try? await Task.sleep(for: .milliseconds(300))
                    Terminals.shared.sendKeys(a.id, "\r")
                }
                if FileManager.default.fileExists(atPath: file) && store.state(a.id).status == .done { break }
                try? await Task.sleep(for: .seconds(2))
            }
            let git = store.tools.git ?? "/usr/bin/git"
            let last = await Shell.run(git, ["log", "-1", "--format=%B"], cwd: a.cwd)
            log("ISSUE-RESULT file=\(FileManager.default.fileExists(atPath: file)) status=\(store.state(a.id).status.rawValue) commit=\(last.out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " | "))")
            await store.deleteAgent(a)
            exit(0)
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
                    print("MEETING-DONE", m.outcomeURL.path, m.commit ?? "no-commit", meetingSpend(m), m.totalTokens, m.note ?? ""); fflush(stdout)
                    if env["HIVEMINDS_TEST_KEEP"] == nil { exit(0) }
                    return
                }
            }
            print("MEETING-TIMEOUT"); fflush(stdout); exit(2)
        }
    }
}
#endif
