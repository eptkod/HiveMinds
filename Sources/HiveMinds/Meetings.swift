import SwiftUI
import AppKit

/// How a meeting runs, as Agent Office has them.
enum MeetingPattern: String, Codable, CaseIterable, Identifiable {
    case debate, lead, mapreduce, redblue, review
    var id: String { rawValue }

    var name: String {
        switch self {
        case .debate: "Debate"
        case .lead: "Lead and team"
        case .mapreduce: "Map-reduce"
        case .redblue: "Red / blue"
        case .review: "Review panel"
        }
    }
    var symbol: String {
        switch self {
        case .debate: "bubble.left.and.bubble.right"
        case .lead: "person.3"
        case .mapreduce: "square.split.2x2"
        case .redblue: "shield.lefthalf.filled"
        case .review: "checklist"
        }
    }
    var blurb: String {
        switch self {
        case .debate: "Each agent proposes, then critiques the others. The chair writes the decision."
        case .lead: "The lead splits the task, the team each do a part, and the lead merges and writes it up."
        case .mapreduce: "The same task over each part in parallel. The head of the table combines the results."
        case .redblue: "Red looks for bugs and security holes, blue fixes them, round after round."
        case .review: "Reviewers read a pull request through their own lens, merged into one review on the PR."
        }
    }
    /// The seat that runs the meeting, and everyone else, for the model pickers.
    var leadSeat: String { seatNames(2)[0] }
    var otherSeats: String {
        switch self {
        case .debate: "Debaters"
        case .lead: "Team"
        case .mapreduce: "Mappers"
        case .redblue: "Blue"
        case .review: "Reviewers"
        }
    }
    var seatRange: ClosedRange<Int> { self == .redblue ? 2...2 : 2...5 }
    var seatsLabel: String { self == .redblue ? "2 agents" : "2–5 agents" }
    /// Whether the number of rounds changes anything.
    var usesRounds: Bool { self == .debate || self == .lead || self == .redblue }
    var roundsExplainer: String {
        switch self {
        case .debate: "Rounds of critique after the opening proposals."
        case .lead: "How many times the team works and the lead reviews."
        case .redblue: "How many times red attacks and blue fixes."
        default: ""
        }
    }
    /// Whether the agents change code, rather than only writing notes.
    var changesCode: Bool { self == .lead || self == .mapreduce || self == .redblue }
    var topicPrompt: String {
        switch self {
        case .debate: "What should they decide?"
        case .lead: "What should the team build?"
        case .mapreduce: "What's the task to split up?"
        case .redblue: "What should red attack? e.g. the login flow"
        case .review: "Anything the reviewers should look out for? (optional)"
        }
    }

    func seatNames(_ count: Int) -> [String] {
        let n = min(max(count, seatRange.lowerBound), seatRange.upperBound)
        switch self {
        case .debate: return ["Chair"] + (2...n).map { "Debater \($0)" }
        case .lead: return ["Lead"] + (2...n).map { "Member \($0)" }
        case .mapreduce: return ["Head"] + (2...n).map { "Mapper \($0)" }
        case .redblue: return ["Red", "Blue"]
        case .review: return Array(["Chair", "Correctness", "Security", "Performance", "Readability and tests"].prefix(n))
        }
    }

    /// What each seat does, for the meeting's brief.
    func seatJob(_ seat: Int) -> String {
        switch (self, seat) {
        case (.debate, 0): "debates, then writes the decision"
        case (.debate, _): "debates"
        case (.lead, 0): "splits the work, reviews it and writes it up"
        case (.lead, _): "does their part of the work"
        case (.mapreduce, 0): "splits the task, then combines the results"
        case (.mapreduce, _): "does one part"
        case (.redblue, 0): "finds bugs and security holes"
        case (.redblue, _): "fixes what red finds"
        case (.review, 0): "reviews the change as a whole, then merges every review into one"
        case (.review, _): "reviews with this focus"
        }
    }
}

enum MeetingStatus: String, Codable {
    case running, paused, finished
    var label: String {
        switch self {
        case .running: "In progress"
        case .paused: "Paused"
        case .finished: "Finished"
        }
    }
}

/// Where a seat is with the current step's turn.
enum TurnState: String, Codable {
    /// Working on it.
    case working
    /// Stopped without writing its file once, and was reminded.
    case nudged
    /// Stopped again without writing it. Waits for you.
    case stuck
    case done
}

/// Which part of a meeting room is open.
enum MeetingTab: Hashable {
    case table, seat(UUID), outcome
}

struct MeetingSeat: Codable, Hashable {
    var name: String
    var agentID: UUID
}

/// A seat's spend, from its session's status line. A session that restarts counts from zero again,
/// so what it had reached before is kept in `base`.
struct SeatUsage: Codable, Hashable {
    var cost = 0.0
    var tokens = 0
    var baseCost = 0.0
    var baseTokens = 0
    var totalCost: Double { baseCost + cost }
    var totalTokens: Int { baseTokens + tokens }

    mutating func record(cost newCost: Double, tokens newTokens: Int) {
        if newCost + 1e-9 < cost || newTokens < tokens {
            baseCost += cost
            baseTokens += tokens
        }
        cost = newCost
        tokens = newTokens
    }
}

struct Meeting: Codable, Identifiable, Hashable {
    var id = UUID()
    var projectID: UUID
    var pattern: MeetingPattern
    var topic: String
    var rounds: Int
    var prNumber: Int?
    /// The model of the seat that runs the meeting, and of everyone else unless `otherModel` is set.
    var model: String
    /// The model every other seat uses, when it differs from the lead seat's. Older meetings have none.
    var otherModel: String?
    var seats: [MeetingSeat] = []
    /// Names the notes folder and the outcome document, e.g. 2026-10-19-pick-a-database.
    var slug: String
    /// Where everyone works: the meeting's own worktree, or the project folder.
    var cwd: String
    var branch: String?
    var status: MeetingStatus = .running
    /// Index into `plan()`.
    var step = 0
    /// The current step's turns, by seat agent.
    var turns: [UUID: TurnState] = [:]
    var usage: [UUID: SeatUsage] = [:]
    /// Where you've put the seats on the table, by agent. Seat order itself decides who chairs, so it stays put.
    var tableOrder: [UUID]?
    /// Seats you've sized by hand on the table, by agent.
    var tablePins: [UUID: TilePin]?
    /// What happened last, shown under the header (paused, a failed commit…).
    var note: String?
    /// The commit with the outcome, when it was committed.
    var commit: String?
    var posted = false
    var createdAt = Date()
    var finishedAt: Date?
    /// Set once you take the meeting off its project's Canvas. It stays on the Meetings page.
    var hiddenFromCanvas: Bool?
    /// The project folder the outcome is saved in, relative to the project. Older meetings have none.
    var outcomeFolder: String?
    /// Where the outcome is saved in the project itself, as a full path. Older meetings have none.
    var savedPath: String?
    /// Whether the meeting skips its remaining rounds once every seat says it's settled. Older meetings have none.
    var endEarly: Bool?
    /// The rounds asked for, kept when the meeting settled early and `rounds` was cut short.
    var plannedRounds: Int?
    /// Whether the app saved the pull request and its diff in the notes, so reviewers don't each fetch them.
    var prSaved: Bool?

    var notesDir: String { ".hiveminds/meetings/\(slug)" }
    /// Where the seats write the outcome, relative to `cwd`.
    var outputPath: String { pattern == .review ? "\(notesDir)/review.md" : "\(outcomeFolder ?? "docs/decisions")/\(slug).md" }
    var outputURL: URL { URL(fileURLWithPath: cwd).appendingPathComponent(outputPath) }
    /// The outcome to show and open: the copy in the project once it's saved there, otherwise the seats' own.
    var outcomeURL: URL {
        if let savedPath, FileManager.default.fileExists(atPath: savedPath) { return URL(fileURLWithPath: savedPath) }
        return outputURL
    }
    var notesURL: URL { URL(fileURLWithPath: cwd).appendingPathComponent(notesDir) }

    var title: String {
        let first = topic.split(separator: "\n").first.map { Agent.roughTitle(String($0)) } ?? ""
        if pattern == .review, let prNumber { return "Review of PR #\(prNumber)" }
        return first.isEmpty ? pattern.name : first
    }
    var totalCost: Double { usage.values.reduce(0) { $0 + $1.totalCost } }
    var totalTokens: Int { usage.values.reduce(0) { $0 + $1.totalTokens } }

    func seatIndex(_ agentID: UUID) -> Int? { seats.firstIndex { $0.agentID == agentID } }
}

struct MeetingTurn {
    let seat: Int
    let instruction: String
    /// The file the seat writes, as a full path. The turn is done once it exists.
    let file: String
}

struct MeetingStep {
    let title: String
    let turns: [MeetingTurn]
    /// The round this step can settle: when every file in it says `Settled: yes`, the rest of the rounds are skipped.
    var settlesRound: Int? = nil
}

/// The line a seat ends a note with when it thinks nothing is left to argue, fix or change.
let settledMarker = "Settled: yes"

extension Meeting {
    /// Every step of the meeting, in order. Seats in the same step take their turns at the same time.
    func plan() -> [MeetingStep] {
        // Full paths in everything a seat reads, so no one resolves them against the wrong folder.
        let notesDir = absolute(self.notesDir)
        let outputPath = absolute(self.outputPath)
        let n = seats.count
        let names = seats.map(\.name)
        let team = Array(1..<max(n, 1))
        let all = Array(0..<n)
        let rounds = max(rounds, 1)
        var steps: [MeetingStep] = []

        func settleAsk() -> String {
            let when = switch pattern {
            case .debate: "you now agree with everyone on the main decision"
            case .lead: "every part is done and fits together, so no one needs another round"
            case .redblue: "you found nothing worth fixing"
            default: "nothing is left to do"
            }
            return "End with the line `\(settledMarker)` if \(when), otherwise `Settled: no`."
        }
        func add(_ title: String, _ key: String, _ who: [Int], output: Bool = false, settles round: Int? = nil,
                 _ instruction: (Int) -> String) {
            let number = String(format: "%02d", steps.count + 1)
            let settles = endEarly == true ? round : nil
            let turns = who.map { seat in
                MeetingTurn(seat: seat, instruction: instruction(seat) + (settles == nil ? "" : " " + settleAsk()),
                            file: output ? outputPath : "\(notesDir)/\(number)-\(key)-\(slugify(names[seat])).md")
            }
            steps.append(MeetingStep(title: title, turns: turns, settlesRound: settles))
        }
        func files(_ step: Int, except seat: Int? = nil) -> String {
            steps[step].turns.filter { $0.seat != seat }.map(\.file).joined(separator: ", ")
        }
        func file(_ step: Int, seat: Int) -> String {
            steps[step].turns.first { $0.seat == seat }?.file ?? notesDir
        }
        let others = { (seat: Int) in names.enumerated().filter { $0.offset != seat }.map(\.element).joined(separator: ", ") }

        switch pattern {
        case .debate:
            add("Proposals", "proposal", all) { _ in
                "Propose how you'd settle the topic: your approach, why, and its main risks, in under 300 words. Look at the code only where it changes the answer."
            }
            for r in 1...rounds {
                let last = steps.count - 1
                add(rounds > 1 ? "Critique, round \(r)" : "Critique", "critique", all, settles: r < rounds ? r : nil) { s in
                    "Read the latest positions of \(others(s)): \(files(last, except: s)). In under 250 words: where they're weak, what you've changed your mind about, and your position now. Don't repeat points already made."
                }
            }
            let last = steps.count - 1
            add("Decision", "decision", [0], output: true) { _ in
                "Read the final positions: \(files(last)). They restate everything that still matters, so earlier notes in \(notesDir) are only for checking a detail. Write the meeting's decision as a concise Markdown document: the question, the options considered, what was decided and why, any disagreement left, and next steps."
            }
        case .lead:
            add("Plan", "plan", [0]) { _ in
                "Split the work into \(team.count) part\(team.count == 1 ? "" : "s"), one for each of \(team.map { names[$0] }.joined(separator: ", ")). Write a short plan with a section per member saying exactly what they own (files and functions), and how the parts fit together. Don't start the work yourself."
            }
            for r in 1...rounds {
                let last = steps.count - 1
                add(rounds > 1 ? "Work, round \(r)" : "Work", "work", team) { s in
                    r == 1
                        ? "Read the plan in \(file(last, seat: 0)). Do your part, as \(names[s]), in the code. Then write a short report (under 200 words): what you did, which files, what's left and anything the lead should know."
                        : "Read the lead's feedback in \(file(last, seat: 0)) and act on what it says about your part. Then write a short update (under 200 words): what you changed and what's left."
                }
                if r < rounds {
                    let work = steps.count - 1
                    add("Review, round \(r)", "feedback", [0], settles: r) { _ in
                        "Read the team's reports: \(files(work)). Check their work with `git diff` rather than reading whole files. Write brief feedback for each member, under their name, saying only what they should change."
                    }
                }
            }
            let last = steps.count - 1
            add("Write-up", "outcome", [0], output: true) { _ in
                "Read the team's reports (\(files(last))) and check the code with `git diff`. Fix small gaps so the parts fit together. Then write the outcome as a Markdown document: what was built, how it fits together, and what's left."
            }
        case .mapreduce:
            add("Split", "split", [0]) { _ in
                "Split the task into \(team.count) part\(team.count == 1 ? "" : "s") that can be done independently, one each for \(team.map { names[$0] }.joined(separator: ", ")). Write a short brief for each part under its own heading. Don't do the parts yourself."
            }
            add("Map", "result", team) { s in
                "Read the section for \(names[s]) in \(file(0, seat: 0)) and do that part. Then write your result: in full if it's text, or, if you changed code, what you changed and where (the code itself stays in the files)."
            }
            add("Reduce", "outcome", [0], output: true) { _ in
                "Read every result: \(files(1)). Combine them into one result as a Markdown document."
            }
        case .redblue:
            for r in 1...rounds {
                let blue = steps.count - 1
                add(rounds > 1 ? "Attack, round \(r)" : "Attack", "findings", [0], settles: r) { _ in
                    r == 1
                        ? "Look for bugs, security holes and edge cases related to the topic. Don't fix anything. List each real finding in a few lines: where it is, how to trigger it and how bad it is. Leave out nitpicks."
                        : "Check blue's fixes in \(file(blue, seat: 1)) (`git diff` shows them) and look again for what's still broken or newly broken. Don't fix anything or repeat fixed findings. List each new finding as before."
                }
                let red = steps.count - 1
                add(rounds > 1 ? "Defend, round \(r)" : "Defend", "fixes", [1]) { _ in
                    "Read red's findings in \(file(red, seat: 0)). Fix them in the code, with tests where it makes sense. Write briefly what you fixed and how, and anything you chose not to fix and why."
                }
            }
            add("Report", "report", [0], output: true) { _ in
                "Read every round's files in \(notesDir). Write a report as a Markdown document: what was found, what was fixed, and what's still open."
            }
        case .review:
            let pr = prNumber.map(String.init) ?? "?"
            let source = prSaved == true
                ? "The pull request is in \(notesDir)/pr.md and its diff in \(notesDir)/pr.diff; open other files only where the diff isn't enough"
                : "Use `gh pr view \(pr)` and `gh pr diff \(pr)`"
            add("Reviews", "review", all) { s in
                "Review pull request #\(pr). \(source). Focus on \(s == 0 ? "the change as a whole" : names[s].lowercased()). Don't change any code or comment on what's outside your focus. List your findings, most important first, each in a few lines with the file, line and a suggested fix. Leave out nitpicks."
            }
            add("Combined review", "combined", [0], output: true) { _ in
                "Read every review: \(files(0)). Merge them into one review for the pull request's author, in Markdown: a short summary, then the findings by importance, without duplicates. Write it as the pull request comment itself."
            }
        }
        return steps
    }

    /// The meeting's brief, saved in its notes folder for every seat to read.
    var brief: String {
        var s = "# \(pattern.name) meeting\n\n\(pattern.blurb)\n\n## Topic\n\n"
        if pattern == .review, let prNumber { s += "Review pull request #\(prNumber).\n\n" }
        s += topic.isEmpty ? "" : topic + "\n\n"
        s += "## At the table\n\n"
        for (i, seat) in seats.enumerated() { s += "- \(seat.name): \(pattern.seatJob(i))\n" }
        s += "\n## How it works\n\nEach turn arrives as a message naming the file to write. Notes for this meeting are in `\(notesDir)`; read other seats' files when your turn says to. The outcome goes in `\(outputPath)`.\n"
        return s
    }

    /// Instructions every seat starts with, on top of Claude Code's own.
    func systemPrompt(for seat: Int) -> String {
        "You're \(seats[seat].name) in a \(pattern.name) meeting run by HiveMinds, with \(seats.count - 1) other Claude Code session\(seats.count == 2 ? "" : "s") working in the same folder. "
            + "Each turn arrives as a message naming the file to write. Do the turn, write that file, then stop and wait for the next turn. "
            + "Don't ask questions unless you can't go on without an answer. "
            + "Other seats read your notes in full, so keep them short: bullets over prose, no preamble, no repeating the brief or what others already said. "
            + "Read only the files your turn names, and don't re-read a file you've already read."
    }

    func absolute(_ path: String) -> String { (cwd as NSString).appendingPathComponent(path) }

    /// The message that hands a seat its turn. Only a seat's first turn points it at the brief; after that it has it.
    func prompt(for turn: MeetingTurn, in step: MeetingStep, first: Bool) -> String {
        let brief = first ? "The topic and who's at the table are in \(absolute(notesDir))/brief.md. " : ""
        return "HiveMinds meeting, turn \"\(step.title)\". You are \(seats[turn.seat].name). \(brief)"
            + "\(turn.instruction) Write it to \(turn.file). When that file is written, stop: the meeting moves on once everyone's turn is in."
    }

    /// Whether the seat has had no turn before this step.
    func isFirstTurn(_ seat: Int, before step: Int, in plan: [MeetingStep]) -> Bool {
        !plan.prefix(step).contains { $0.turns.contains { $0.seat == seat } }
    }
}

/// Meeting settings as plain values, for code outside a view.
enum MeetingDefaults {
    private static var d: UserDefaults { .standard }
    static var model: String { d.string(forKey: SettingKey.meetingModel) ?? SettingDefault.meetingModel }
    static var splitModels: Bool { d.object(forKey: SettingKey.meetingSplitModels) as? Bool ?? SettingDefault.meetingSplitModels }
    static var otherModel: String { d.string(forKey: SettingKey.meetingOtherModel) ?? SettingDefault.meetingOtherModel }
    static var seats: Int { d.object(forKey: SettingKey.meetingSeats) as? Int ?? SettingDefault.meetingSeats }
    static var rounds: Int { d.object(forKey: SettingKey.meetingRounds) as? Int ?? SettingDefault.meetingRounds }
    static var acceptEdits: Bool { d.object(forKey: SettingKey.meetingAcceptEdits) as? Bool ?? SettingDefault.meetingAcceptEdits }
    static var commit: Bool { d.object(forKey: SettingKey.meetingCommit) as? Bool ?? SettingDefault.meetingCommit }
    static var endEarly: Bool { d.object(forKey: SettingKey.meetingEndEarly) as? Bool ?? SettingDefault.meetingEndEarly }
    /// The outcome folder, relative to the project, cleaned of stray slashes and spaces.
    static var outcomeFolder: String {
        let raw = d.string(forKey: SettingKey.meetingOutcomeFolder) ?? SettingDefault.meetingOutcomeFolder
        let parts = raw.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.isEmpty ? SettingDefault.meetingOutcomeFolder : parts.joined(separator: "/")
    }
}

// MARK: Running meetings

/// A meeting is a set of ordinary Claude Code sessions, one per seat, in one folder. Each step, the app types
/// a turn into each seat's terminal naming the file to write. When a seat's Claude Code stops (its Stop hook)
/// and the file is there, its turn is done; when every turn in the step is done, the next step starts.
extension AppStore {
    func meeting(_ id: UUID) -> Meeting? { meetings.first { $0.id == id } }
    func meeting(for agentID: UUID) -> Meeting? { agent(agentID)?.meetingID.flatMap { meeting($0) } }
    func seatAgents(_ meeting: Meeting) -> [Agent] { meeting.seats.compactMap { agent($0.agentID) } }

    func updateMeeting(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let i = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[i])
        save()
    }

    func openMeeting(_ id: UUID, tab: MeetingTab = .table) {
        mode = .meetings
        meetingSelection = id
        meetingTab = tab
    }

    /// A project's meetings that show on its Canvas and tab row: all of them, until you take one off.
    func canvasMeetings(in project: Project) -> [Meeting] {
        meetings.filter { $0.projectID == project.id && $0.hiddenFromCanvas != true }
    }

    /// Takes a meeting off its project's Canvas. It stays on the Meetings page, where it can be opened as before.
    func hideMeetingFromCanvas(_ id: UUID) {
        guard let m = meeting(id) else { return }
        updateMeeting(id) { $0.hiddenFromCanvas = true }
        if selection == .meeting(id) { selection = .project(m.projectID) }
    }

    /// Opens a meeting's overview as a tab in its project's workspace, putting it back on the Canvas if needed.
    func openMeetingOverview(_ id: UUID) {
        guard meeting(id) != nil else { return }
        if meeting(id)?.hiddenFromCanvas == true { updateMeeting(id) { $0.hiddenFromCanvas = nil } }
        mode = .agents
        selection = .meeting(id)
    }

    func beginNewMeeting(pattern: MeetingPattern? = nil) {
        newMeetingPattern = pattern
        showingNewMeeting = true
    }

    func startMeeting(projectID: UUID, pattern: MeetingPattern, topic: String, seats: Int,
                      rounds: Int, prNumber: Int?, model: String, otherModel: String? = nil) async throws {
        guard tools.claude != nil else { throw NewAgentError("Meetings run on Claude Code, which isn't installed.") }
        guard let project = project(projectID) else { throw NewAgentError("Pick a project first.") }
        let topic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        if pattern == .review && prNumber == nil { throw NewAgentError("Enter the number of the pull request to review.") }
        if pattern != .review && topic.isEmpty { throw NewAgentError("Say what the meeting is about.") }

        let date = Date().formatted(.iso8601.year().month().day())
        var base = pattern == .review ? "review-pr-\(prNumber ?? 0)" : slugify(Agent.roughTitle(topic))
        if base.isEmpty { base = pattern.rawValue }
        let suffix = String(UUID().uuidString.prefix(4)).lowercased()
        var cwd = project.path
        var branch: String?
        if project.isGitRepo {
            (cwd, branch) = try await makeWorktree(project: project, slug: "meeting-\(base)-\(suffix)")
        }
        var meeting = Meeting(projectID: projectID, pattern: pattern, topic: topic, rounds: rounds,
                              prNumber: prNumber, model: model, otherModel: otherModel == model ? nil : otherModel, slug: "\(date)-\(base)", cwd: cwd, branch: branch)
        let folder = MeetingDefaults.outcomeFolder
        meeting.outcomeFolder = folder
        let saved = { "\(project.path)/\(folder)/\(meeting.slug).md" }
        // Don't overwrite an earlier meeting's outcome from the same day.
        if FileManager.default.fileExists(atPath: meeting.outputURL.path) || FileManager.default.fileExists(atPath: saved()) {
            meeting.slug += "-\(suffix)"
        }
        meeting.savedPath = saved()
        meeting.endEarly = MeetingDefaults.endEarly
        let pullRequest = pattern == .review ? await fetchPullRequest(prNumber ?? 0, in: project) : nil
        meeting.prSaved = pullRequest != nil

        for (i, name) in pattern.seatNames(seats).enumerated() {
            let agent = Agent(projectID: projectID, title: name, provider: .claude, model: i == 0 ? model : meeting.otherModel ?? model,
                              effort: AgentDefaults.effort, access: AgentDefaults.access, role: "",
                              cwd: cwd, branch: branch, meetingID: meeting.id)
            meeting.seats.append(MeetingSeat(name: name, agentID: agent.id))
            agents.append(agent)
            live[agent.id] = LiveState(status: .asleep, activity: "Waiting for their turn")
        }
        for (i, seat) in meeting.seats.enumerated() {
            if let a = agents.firstIndex(where: { $0.id == seat.agentID }) { agents[a].role = meeting.systemPrompt(for: i) }
        }
        do {
            try FileManager.default.createDirectory(at: meeting.notesURL, withIntermediateDirectories: true)
            try meeting.brief.write(to: meeting.notesURL.appendingPathComponent("brief.md"), atomically: true, encoding: .utf8)
            if let pullRequest {
                try pullRequest.view.write(to: meeting.notesURL.appendingPathComponent("pr.md"), atomically: true, encoding: .utf8)
                try pullRequest.diff.write(to: meeting.notesURL.appendingPathComponent("pr.diff"), atomically: true, encoding: .utf8)
            }
        } catch {
            throw NewAgentError("Couldn't write the meeting's notes folder. \(error.localizedDescription)")
        }
        meetings.append(meeting)
        save()
        openMeeting(meeting.id)
        beginStep(meeting.id)
    }

    /// Hands every seat in the current step its turn, or wraps up when there are no steps left.
    private func beginStep(_ id: UUID) {
        guard var m = meeting(id) else { return }
        let plan = m.plan()
        guard m.step < plan.count else { finishMeeting(id); return }
        let step = plan[m.step]
        m.turns = [:]
        for t in step.turns { m.turns[m.seats[t.seat].agentID] = .working }
        m.status = .running
        m.note = nil
        updateMeeting(id) { $0 = m }
        for t in step.turns {
            let agentID = m.seats[t.seat].agentID
            sendInput(agentID, m.prompt(for: t, in: step, first: m.isFirstTurn(t.seat, before: m.step, in: plan)))
            if state(agentID).status != .starting { setStatus(agentID, .working, "Their turn: \(step.title)") }
        }
    }

    /// Fetches the pull request and its diff once, to save in the notes so each reviewer reads a file instead
    /// of fetching them again. Nothing when gh can't, and then reviewers fetch them themselves.
    private func fetchPullRequest(_ pr: Int, in project: Project) async -> (view: String, diff: String)? {
        guard let gh = tools.gh else { return nil }
        let view = await Shell.run(gh, ["pr", "view", String(pr)], cwd: project.path)
        let diff = await Shell.run(gh, ["pr", "diff", String(pr)], cwd: project.path)
        return view.ok && diff.ok ? (view.out, diff.out) : nil
    }

    /// Sends a message to an agent: as its first prompt if it has never run, typed into its terminal if it's
    /// ready, or typed once its session has started.
    func sendInput(_ agentID: UUID, _ text: String) {
        guard let agent = agent(agentID) else { return }
        stopped.remove(agentID)
        if !Terminals.shared.isRunning(agentID) {
            if agent.hasStarted { pendingInput[agentID] = text } else { update(agentID) { $0.pendingTask = text } }
            if let fresh = self.agent(agentID) { _ = Terminals.shared.view(for: fresh) }
            terminalGeneration[agentID, default: 0] += 1
        } else if state(agentID).status == .starting {
            pendingInput[agentID] = text
        } else {
            Terminals.shared.type(agentID, text)
        }
    }

    private func turn(of agentID: UUID, in m: Meeting) -> MeetingTurn? {
        guard let seat = m.seatIndex(agentID) else { return nil }
        let plan = m.plan()
        guard m.step < plan.count else { return nil }
        return plan[m.step].turns.first { $0.seat == seat }
    }

    private func isWritten(_ file: String, in m: Meeting) -> Bool {
        let path = file.hasPrefix("/") ? file : m.absolute(file)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        return size > 0
    }

    /// A seat's Claude Code stopped. Its turn is done if it wrote its file; if not, it gets one reminder,
    /// and after that it waits for you.
    func meetingTurnEnded(_ agentID: UUID) {
        guard let m = meeting(for: agentID), m.status == .running,
              let state = m.turns[agentID], state != .done, let t = turn(of: agentID, in: m) else { return }
        refreshUsage(m.id)
        if isWritten(t.file, in: m) {
            updateMeeting(m.id) { $0.turns[agentID] = .done }
            setStatus(agentID, .done, "Turn done")
            advanceIfReady(m.id)
        } else if state == .working {
            updateMeeting(m.id) { $0.turns[agentID] = .nudged }
            sendInput(agentID, "You stopped before writing \(t.file). Write it now, then stop.")
        } else {
            updateMeeting(m.id) { $0.turns[agentID] = .stuck }
            setStatus(agentID, .needsYou, "Stopped without writing \((t.file as NSString).lastPathComponent)")
        }
    }

    private func advanceIfReady(_ id: UUID) {
        guard let m = meeting(id), m.status == .running, !m.turns.isEmpty, m.turns.values.allSatisfy({ $0 == .done }) else { return }
        let plan = m.plan()
        if m.step < plan.count, let round = plan[m.step].settlesRound, round < m.rounds || m.pattern == .redblue,
           plan[m.step].turns.allSatisfy({ saysSettled($0.file, in: m) }) {
            // Everyone says there's nothing left, so the rest of the rounds would only cost tokens. Go to the write-up.
            updateMeeting(id) {
                $0.plannedRounds = $0.plannedRounds ?? $0.rounds
                $0.rounds = round
                $0.step = $0.plan().count - 1
            }
            beginStep(id)
            updateMeeting(id) { $0.note = "Settled after round \(round) of \(m.plannedRounds ?? m.rounds), so the rest were skipped." }
            return
        }
        updateMeeting(id) { $0.step += 1 }
        beginStep(id)
    }

    /// Whether a seat's note ends by saying it's settled.
    private func saysSettled(_ file: String, in m: Meeting) -> Bool {
        let path = file.hasPrefix("/") ? file : m.absolute(file)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " *`_>-")).lowercased() == settledMarker.lowercased()
        }
    }

    /// You decided a seat's turn is good enough, file or not.
    func markTurnDone(_ agentID: UUID) {
        guard let m = meeting(for: agentID) else { return }
        updateMeeting(m.id) { $0.turns[agentID] = .done }
        setStatus(agentID, .done, "Turn done")
        advanceIfReady(m.id)
    }

    func pauseMeeting(_ id: UUID) {
        guard let m = meeting(id) else { return }
        for seat in m.seats {
            pendingInput[seat.agentID] = nil
            stop(seat.agentID)
            setStatus(seat.agentID, .asleep, "Paused")
        }
        updateMeeting(id) { $0.status = .paused; $0.note = "Paused. Resume to carry on where it left off." }
    }

    /// Carries on with the current step: turns whose file is already there count as done, the rest are sent again.
    func resumeMeeting(_ id: UUID) {
        guard let m = meeting(id), m.status != .finished else { return }
        let plan = m.plan()
        guard m.step < plan.count else { finishMeeting(id); return }
        updateMeeting(id) { $0.status = .running; $0.note = nil }
        let step = plan[m.step]
        for t in step.turns {
            let agentID = m.seats[t.seat].agentID
            if m.turns[agentID] == .done || isWritten(t.file, in: m) {
                updateMeeting(id) { $0.turns[agentID] = .done }
            } else {
                updateMeeting(id) { $0.turns[agentID] = .working }
                sendInput(agentID, m.prompt(for: t, in: step, first: m.isFirstTurn(t.seat, before: m.step, in: plan)))
                if state(agentID).status != .starting { setStatus(agentID, .working, "Their turn: \(step.title)") }
            }
        }
        advanceIfReady(id)
    }

    /// Every step is done: stop the seats, commit the outcome on the meeting's branch, and show it.
    private func finishMeeting(_ id: UUID) {
        guard let m = meeting(id) else { return }
        for seat in m.seats {
            stop(seat.agentID)
            setStatus(seat.agentID, .asleep, "Meeting over")
        }
        updateMeeting(id) { $0.status = .finished; $0.finishedAt = Date(); $0.turns = [:] }
        Sounds.play(.done)
        let saved = saveOutcome(m)
        if meetingSelection == id { meetingTab = .outcome }
        notice = "\(m.pattern.name) finished. The outcome is saved in \(saved)."
        Task {
            if m.pattern != .review, m.branch != nil, MeetingDefaults.commit { await commitOutcome(id) }
            // The status lines catch up a moment after the last turn.
            try? await Task.sleep(for: .seconds(3))
            refreshUsage(id)
        }
    }

    /// Copies the outcome into the project's outcome folder, where it's easy to find, when the seats wrote it
    /// somewhere else (the meeting's own branch, or its notes). Says where it ended up.
    private func saveOutcome(_ m: Meeting) -> String {
        guard let savedPath = m.savedPath, let project = project(m.projectID) else { return m.outputPath }
        let shown = "\(relative(savedPath, to: project.path)) in \(project.name)"
        let source = m.outputURL, target = URL(fileURLWithPath: savedPath)
        guard source.path != savedPath else { return shown }
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
            return shown
        } catch {
            updateMeeting(m.id) { $0.note = "Couldn't save the outcome in the project folder: \(error.localizedDescription)" }
            return source.path
        }
    }

    private func relative(_ path: String, to base: String) -> String {
        path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    private func commitOutcome(_ id: UUID) async {
        guard let m = meeting(id), let git = tools.git else { return }
        _ = await Shell.run(git, ["-C", m.cwd, "add", "-A"])
        let r = await Shell.run(git, ["-C", m.cwd, "commit", "-m", "Meeting (\(m.pattern.name)): \(m.title)"])
        if r.ok {
            let head = await Shell.run(git, ["-C", m.cwd, "rev-parse", "--short", "HEAD"])
            updateMeeting(id) { $0.commit = head.out.trimmingCharacters(in: .whitespacesAndNewlines) }
        } else if !r.message.contains("nothing to commit") {
            updateMeeting(id) { $0.note = "Couldn't commit the outcome: \(r.message)" }
        }
    }

    /// Reads each seat's latest cost and token count from its status line.
    func refreshUsage(_ id: UUID) {
        guard let m = meeting(id) else { return }
        var usage = m.usage
        for seat in m.seats {
            guard let data = try? Data(contentsOf: statusFile(for: seat.agentID)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let cost = (json["cost"] as? [String: Any])?["total_cost_usd"] as? Double ?? 0
            let window = json["context_window"] as? [String: Any] ?? [:]
            let tokens = (window["total_input_tokens"] as? Int ?? 0) + (window["total_output_tokens"] as? Int ?? 0)
            usage[seat.agentID, default: SeatUsage()].record(cost: cost, tokens: tokens)
        }
        if usage != m.usage { updateMeeting(id) { $0.usage = usage } }
    }

    /// Posts a review panel's combined review on its pull request. Public, so the view asks first.
    func postReview(_ id: UUID) async {
        guard let m = meeting(id), let gh = tools.gh, let pr = m.prNumber, let project = project(m.projectID) else { return }
        let r = await Shell.run(gh, ["pr", "review", String(pr), "--comment", "--body-file", m.outputURL.path], cwd: project.path)
        if r.ok {
            updateMeeting(id) { $0.posted = true }
            notice = "The review is posted on pull request #\(pr)."
        } else {
            errorMessage = "Couldn't post the review. \(r.message)"
        }
    }

    /// Removes the meeting and its seats. Its branch, and so its committed outcome, stays. Its folder goes
    /// only if nothing in it is left uncommitted.
    func deleteMeeting(_ m: Meeting) async {
        remember(agents.filter { $0.meetingID == m.id })
        for seat in m.seats {
            Terminals.shared.stop(seat.agentID)
            pendingInput[seat.agentID] = nil
            live.removeValue(forKey: seat.agentID)
            stopped.remove(seat.agentID)
            spend.forget(seat.agentID)
            try? FileManager.default.removeItem(at: eventsFile(for: seat.agentID))
            try? FileManager.default.removeItem(at: statusFile(for: seat.agentID))
        }
        agents.removeAll { $0.meetingID == m.id }
        meetings.removeAll { $0.id == m.id }
        if meetingSelection == m.id { meetingSelection = nil }
        if selection == .meeting(m.id) { selection = .project(m.projectID) }
        save()
        if m.branch != nil, let git = tools.git, let project = project(m.projectID) {
            // Meeting notes are ignored files, so they'd stop a plain remove. They go with the meeting.
            try? FileManager.default.removeItem(at: m.notesURL)
            let r = await Shell.run(git, ["-C", project.path, "worktree", "remove", m.cwd])
            if !r.ok { notice = "The meeting's folder was kept because it has changes that aren't committed: \(m.cwd)" }
        }
    }
}
