import Foundation
import Testing
import SwiftTerm
@testable import HiveMindsCore

/// A snapshot fed into a fresh terminal must rebuild exactly what a terminal that saw every byte has.
/// Also checks the vendored SwiftTerm's fixes.
@Suite struct TerminalSnapshotTests {
    final class Quiet: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }
    let quiet = Quiet()

    func terminal(cols: Int = 60, rows: Int = 12) -> Terminal {
        Terminal(delegate: quiet, options: TerminalOptions(cols: cols, rows: rows, scrollback: 500))
    }

    /// Feeds `first` to a live terminal, snapshots it into a fresh one, then feeds `then` to both,
    /// and checks they match after each step.
    func roundTrip(_ first: String, then: String = "", cols: Int = 60, rows: Int = 12) {
        let live = terminal(cols: cols, rows: rows)
        live.feed(text: first)
        let copy = terminal(cols: cols, rows: rows)
        copy.feed(byteArray: TerminalSnapshot.make(live))
        #expect(TerminalSnapshot.diff(live, copy) == [])
        live.feed(text: then)
        copy.feed(text: then)
        #expect(TerminalSnapshot.diff(live, copy) == [])
        // A snapshot of the copy is byte for byte the snapshot of the original.
        #expect(TerminalSnapshot.make(live) == TerminalSnapshot.make(copy))
    }

    @Test func coloursStylesAndScrollback() {
        var text = "\u{1b}[1;31mbold red\u{1b}[0m \u{1b}[38;5;208m256\u{1b}[0m \u{1b}[38;2;10;200;120mtrue\u{1b}[0m \u{1b}[4;3;9;2;7mmixed\u{1b}[0m\r\n"
        for i in 0..<80 { text += "line \(i) \u{1b}[3\(i % 8)mcolour\u{1b}[0m\r\n" }
        roundTrip(text, then: "more after\r\n")
    }

    @Test func wideCharactersAndWrappedLines() {
        let long = String(repeating: "=", count: 150)
        roundTrip("wide: 你好世界 🙂👍 combining: e\u{301} done\r\n\(long)\r\nend", then: "\r\n你好\(long)")
    }

    @Test func emptyCellsStayEmptyAndColouredErasesKeepTheirColour() {
        roundTrip("gap:\u{1b}[20Cafter\r\n\u{1b}[41mred\u{1b}[5Xerased\u{1b}[0m\r\n\u{1b}[42m\u{1b}[Kgreen to the end\u{1b}[0m\r\n",
                  then: "\u{1b}[1;1H\u{1b}[K")
    }

    @Test func hyperlinks() {
        roundTrip("see \u{1b}]8;;https://example.com/docs\u{1b}\\the docs\u{1b}]8;;\u{1b}\\ here\r\n")
    }

    @Test func alternateScreenModesAndScrollRegion() {
        let setup = "normal text\r\n" + (0..<30).map { "scrollback \($0)\r\n" }.joined()
            + "\u{1b}[?1049h\u{1b}[2J\u{1b}[H\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?1h\u{1b}=\u{1b}[?25l\u{1b}[?1004h\u{1b}[3;10r"
            + "\u{1b}[1;1HTop\u{1b}[5;5H\u{1b}[32mgreen\u{1b}[48;2;40;40;90m"
        roundTrip(setup, then: " typed\r\nmore\u{1b}[?1049l back")
    }

    @Test func kittyKeyboardQueriesDontMoveTheCursor() {
        // Claude Code saves the cursor, then asks about the kitty keyboard protocol. SwiftTerm 1.11.2 took
        // `CSI ? u` for "restore cursor" and jumped back. The vendored copy ignores it.
        let t = terminal()
        t.feed(text: "\u{1b}[3;5H\u{1b}7\u{1b}[8;20H\u{1b}[?u\u{1b}[>5u\u{1b}[<u")
        #expect(t.getCursorLocation().x == 19 && t.getCursorLocation().y == 7)
        // A plain `CSI u` still restores it.
        t.feed(text: "\u{1b}[s\u{1b}[1;1H\u{1b}[u")
        #expect(t.getCursorLocation().x == 19 && t.getCursorLocation().y == 7)
    }

    @Test func screenTextIsTheVisibleRows() {
        let t = terminal(cols: 20, rows: 3)
        t.feed(text: "a\r\nb\r\nc\r\nd")
        #expect(TerminalSnapshot.screenText(t) == "b\nc\nd")
    }
}
