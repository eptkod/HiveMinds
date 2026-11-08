import Foundation
import SwiftTerm

/// One numbered choice of a menu on an agent's screen ("❯ 1. Yes, auto-accept edits").
package struct MenuOption: Equatable, Sendable {
    package var number: Int
    package var label: String

    package init(number: Int, label: String) {
        self.number = number
        self.label = label
    }
}

/// Answering an agent's prompt from outside its terminal (a tile, a card, a teammate's Mac) by pressing the same
/// keys you would in the terminal, so the terminal stays the one source of truth. Each function returns the keys
/// to press, one after another, or nil when there's nothing sensible to press.
package enum PromptKeys {
    /// Says yes once to a permission prompt (its first option).
    package static let allow = ["1"]
    /// Says no to a permission prompt, skips a question, or stops a plan. Claude Code then waits for you.
    package static let decline = ["\u{1b}"]

    /// Approves a plan and lets it start, keeping the conversation. Claude Code's list of choices changes with
    /// the session (some start with "clear context", some offer bypass or auto mode), so the number to press is
    /// read off the screen: "manually approve edits" for an agent on Manual review, otherwise the first "Yes"
    /// that keeps the context.
    package static func approvePlan(_ options: [MenuOption], manualReview: Bool) -> [String]? {
        let keep = options.filter { $0.label.hasPrefix("Yes") && !$0.label.localizedCaseInsensitiveContains("clear context") }
        let manual = manualReview ? keep.first { $0.label.localizedCaseInsensitiveContains("manually") } : nil
        guard let pick = manual ?? keep.first else { return nil }
        return ["\(pick.number)"]
    }

    /// The plan menu's choice for sending it back with changes. Claude Code has called it "No, keep planning"
    /// and, since late 2026, "Tell Claude what to change".
    package static let keepPlanningLabels = ["No, keep planning", "Tell Claude what to change"]

    /// Sends a plan back with what to change, so it keeps planning. Nil when there's nothing to say or no
    /// such choice on screen; then the plan should just be declined.
    package static func keepPlanning(_ options: [MenuOption], feedback: String) -> [String]? {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !text.isEmpty,
              let no = options.last(where: { o in keepPlanningLabels.contains { o.label.hasPrefix($0) } }) else { return nil }
        return ["\(no.number)", text, "\r"]
    }

    /// Answers every question in an AskUserQuestion prompt: an option's index, or your own words.
    package static func answer(_ questions: [AskQuestion], _ answers: [QuestionAnswer]) -> [String]? {
        guard answers.count == questions.count else { return nil }
        var keys: [String] = []
        for (q, a) in zip(questions, answers) {
            switch a {
            case .option(let i): keys.append("\(i + 1)")
            case .text(let text):
                // The option after the listed ones is "Type something".
                keys.append("\(q.options.count + 1)")
                keys.append(text.replacingOccurrences(of: "\n", with: " "))
                keys.append("\r")
            }
        }
        // With more than one question, Claude Code shows your answers and asks you to submit them.
        if questions.count > 1 { keys.append("1") }
        return keys
    }

    /// The numbered choices of the menu on screen, read from the bottom up so a numbered list higher up
    /// (in a plan, say) doesn't count.
    package static func menuOptions(in terminal: Terminal) -> [MenuOption] {
        var found: [Int: String] = [:]
        for row in stride(from: terminal.rows - 1, through: 0, by: -1) {
            // Cells a program skipped over (Claude Code moves the cursor rather than writing spaces) come back
            // as NUL characters; they're blanks.
            guard let line = terminal.getLine(row: row)?.translateToString(trimRight: true)
                .replacingOccurrences(of: "\u{0}", with: " ") else { continue }
            let text = line.trimmingCharacters(in: .whitespaces).drop { "❯›>│ ".contains($0) }
            guard let dot = text.firstIndex(of: "."), let n = Int(text[..<dot]), found[n] == nil else { continue }
            if found.keys.contains(where: { $0 < n }) { break }
            found[n] = text[text.index(after: dot)...].trimmingCharacters(in: .whitespaces)
        }
        return found.sorted { $0.key < $1.key }.map { MenuOption(number: $0.key, label: $0.value) }
    }
}

/// Something you can do about what an agent is asking, from a tile, a card or (later) another device.
package enum PromptAction: Equatable, Sendable {
    case allow
    case decline
    case approvePlan
    case keepPlanning(String)
    case answer([QuestionAnswer])
}

/// What to do for a `PromptAction`: the keys to press, and the status to show once they're pressed.
package enum PromptResponse: Equatable, Sendable {
    case press([String], status: AgentStatus, activity: String)
    /// The plan's choices weren't on screen, so it has to be approved in the terminal.
    case planChoicesNotFound
    /// It isn't asking that (any more), so there's nothing to do.
    case nothing
}

package enum PromptResponder {
    /// `ask` is what the agent is waiting on; `menu` reads the menu on its screen, only when needed.
    package static func respond(_ action: PromptAction, ask: PendingAsk.Kind?, access: Access?,
                                menu: () -> [MenuOption]) -> PromptResponse {
        guard let ask else { return .nothing }
        switch action {
        case .allow:
            return .press(PromptKeys.allow, status: .working, activity: "Allowed")
        case .decline:
            return declined
        case .approvePlan:
            guard case .plan = ask else { return .nothing }
            guard let keys = PromptKeys.approvePlan(menu(), manualReview: access == .manual) else { return .planChoicesNotFound }
            return .press(keys, status: .working, activity: "Plan approved")
        case .keepPlanning(let feedback):
            guard case .plan = ask else { return .nothing }
            // With nothing to say, or no such choice on screen, it just stops and waits.
            guard let keys = PromptKeys.keepPlanning(menu(), feedback: feedback) else { return declined }
            return .press(keys, status: .working, activity: "Reworking the plan")
        case .answer(let answers):
            guard case .questions(let questions) = ask, let keys = PromptKeys.answer(questions, answers) else { return .nothing }
            return .press(keys, status: .working, activity: "Answered")
        }
    }

    private static let declined = PromptResponse.press(PromptKeys.decline, status: .idle, activity: "You said no. Tell it what to do instead.")
}
