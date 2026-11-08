import Foundation
import Testing
import SwiftTerm
@testable import HiveMindsCore

@Suite struct PromptKeysTests {
    final class Quiet: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
    let quiet = Quiet()

    func screen(_ text: String, cols: Int = 80, rows: Int = 24) -> Terminal {
        let t = Terminal(delegate: quiet, options: TerminalOptions(cols: cols, rows: rows, scrollback: 100))
        t.feed(text: text.replacingOccurrences(of: "\n", with: "\r\n"))
        return t
    }

    @Test func readsTheMenuAtTheBottomNotANumberedListAbove() {
        let t = screen("""
        Plan:
        1. Read the code
        2. Fix the bug
        3. Write tests

        Would you like to proceed?
        ❯ 1. Yes, and auto-accept edits
          2. Yes, and manually approve edits
          3. No, keep planning
        """)
        #expect(PromptKeys.menuOptions(in: t) == [
            MenuOption(number: 1, label: "Yes, and auto-accept edits"),
            MenuOption(number: 2, label: "Yes, and manually approve edits"),
            MenuOption(number: 3, label: "No, keep planning"),
        ])
    }

    @Test func readsMenusDrawnWithCursorMovesInsteadOfSpaces() {
        // Claude Code's plan menu (late 2026): gaps are skipped with cursor moves, so those cells stay empty.
        let t = screen("Would you like to proceed?\n\u{1b}[3C❯\u{1b}[1C1. Yes, and use auto mode\n     2. Yes, manually approve edits\n"
                       + "  \u{1b}[3C3. Tell Claude what to change\n        shift+tab to approve with this feedback")
        let options = PromptKeys.menuOptions(in: t)
        #expect(options.map(\.number) == [1, 2, 3])
        #expect(options.first?.label == "Yes, and use auto mode")
        #expect(PromptKeys.approvePlan(options, manualReview: false) == ["1"])
        #expect(PromptKeys.approvePlan(options, manualReview: true) == ["2"])
        #expect(PromptKeys.keepPlanning(options, feedback: "Use SQLite") == ["3", "Use SQLite", "\r"])
    }

    @Test func approvingAPlanKeepsTheContext() {
        let options = [MenuOption(number: 1, label: "Yes, clear context and auto-accept edits"),
                       MenuOption(number: 2, label: "Yes, and auto-accept edits"),
                       MenuOption(number: 3, label: "Yes, manually approve edits"),
                       MenuOption(number: 4, label: "No, keep planning")]
        #expect(PromptKeys.approvePlan(options, manualReview: false) == ["2"])
        #expect(PromptKeys.approvePlan(options, manualReview: true) == ["3"])
        #expect(PromptKeys.approvePlan([MenuOption(number: 1, label: "No")], manualReview: false) == nil)
    }

    @Test func keepPlanningTypesTheFeedback() {
        let options = [MenuOption(number: 1, label: "Yes"), MenuOption(number: 2, label: "No, keep planning")]
        #expect(PromptKeys.keepPlanning(options, feedback: " Use SQLite\ninstead ") == ["2", "Use SQLite instead", "\r"])
        #expect(PromptKeys.keepPlanning(options, feedback: "  ") == nil)
        #expect(PromptKeys.keepPlanning([MenuOption(number: 1, label: "Yes")], feedback: "x") == nil)
    }

    @Test func answeringQuestions() {
        let q = [AskQuestion(header: "", question: "A?", options: ["x", "y"], multiSelect: false),
                 AskQuestion(header: "", question: "B?", options: ["z"], multiSelect: false)]
        #expect(PromptKeys.answer(q, [.option(1), .text("my\nwords")]) == ["2", "2", "my words", "\r", "1"])
        #expect(PromptKeys.answer(Array(q.prefix(1)), [.option(0)]) == ["1"])
        #expect(PromptKeys.answer(q, [.option(0)]) == nil)
    }
}
