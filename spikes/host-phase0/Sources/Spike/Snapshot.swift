import Foundation
import SwiftTerm

/// Turns a headless terminal's state into bytes that rebuild the same screen and scrollback in a fresh terminal.
enum Snapshot {
    static func make(_ t: Terminal) -> [UInt8] {
        let m = t.hiveMindsModes
        var out = "\u{1b}c"  // full reset
        let normal = t.hiveMindsNormalBuffer
        out += render(t, normal, lines: 0..<normal.hiveMindsLineCount)
        out += regionAndCursor(normal, rows: t.rows)
        if m.alternateScreen {
            let alt = t.hiveMindsAltBuffer
            out += "\u{1b}[?1049h\u{1b}[H"
            out += render(t, alt, lines: alt.yDisp..<alt.hiveMindsLineCount)
            out += regionAndCursor(alt, rows: t.rows)
        }
        if m.originMode { out += "\u{1b}[?6h" }
        if !m.wraparound { out += "\u{1b}[?7l" }
        if m.reverseWraparound { out += "\u{1b}[?45h" }
        if m.insertMode { out += "\u{1b}[4h" }
        if m.applicationCursor { out += "\u{1b}[?1h" }
        if m.applicationKeypad { out += "\u{1b}=" }
        if m.bracketedPaste { out += "\u{1b}[?2004h" }
        if m.sendFocus { out += "\u{1b}[?1004h" }
        switch m.mouseMode {
        case .off: break
        case .x10: out += "\u{1b}[?9h"
        case .vt200: out += "\u{1b}[?1000h"
        case .buttonEventTracking: out += "\u{1b}[?1002h"
        case .anyEvent: out += "\u{1b}[?1003h"
        default: break
        }
        if let e = m.mouseEncodingMode { out += "\u{1b}[?\(e)h" }
        if m.cursorHidden { out += "\u{1b}[?25l" }
        out += sgr(t.currentAttribute)
        return Array(out.utf8)
    }

    private static func regionAndCursor(_ b: Buffer, rows: Int) -> String {
        var out = "\u{1b}[0m"
        if b.scrollTop != 0 || b.scrollBottom != rows - 1 { out += "\u{1b}[\(b.scrollTop + 1);\(b.scrollBottom + 1)r" }
        return out + "\u{1b}[\(b.y + 1);\(b.x + 1)H"
    }

    static let blank = CharData.Null.attribute

    private static func render(_ t: Terminal, _ b: Buffer, lines: Range<Int>) -> String {
        let cols = t.cols
        var out = ""
        var attr = blank
        var link: String? = nil
        for row in lines {
            let nextWrapped = row + 1 < lines.upperBound && b.hiveMindsIsWrapped(row + 1)
            if row != lines.lowerBound && !b.hiveMindsIsWrapped(row) { out += "\r\n" }
            var last = cols - 1
            if !nextWrapped {
                while last >= 0 {
                    let c = b.getChar(atBufferRelative: Position(col: last, row: row))
                    if !c.hiveMindsIsEmpty || c.attribute != blank || c.hasPayload { break }
                    last -= 1
                }
            }
            var col = 0
            while col <= last {
                let c = b.getChar(atBufferRelative: Position(col: col, row: row))
                if c.width == 0 { col += 1; continue }
                let url = c.getPayload() as? String
                if url != link {
                    out += "\u{1b}]8;" + (url ?? ";") + "\u{1b}\\"
                    link = url
                }
                if c.hiveMindsIsEmpty && !nextWrapped {
                    // A run of never-written cells: skip over it rather than writing spaces, so the cells stay empty.
                    // Coloured empty cells (from an erase with a background) are recreated with ECH, which fills
                    // with empty cells in the current colours and doesn't move the cursor.
                    var n = 1
                    while col + n <= last {
                        let next = b.getChar(atBufferRelative: Position(col: col + n, row: row))
                        guard next.hiveMindsIsEmpty, next.attribute == c.attribute, next.width != 0,
                              (next.getPayload() as? String) == url else { break }
                        n += 1
                    }
                    if c.attribute != blank {
                        if c.attribute != attr { out += sgr(c.attribute); attr = c.attribute }
                        out += "\u{1b}[\(n)X"
                    }
                    out += "\u{1b}[\(n)C"
                    col += n
                    continue
                }
                if c.attribute != attr { out += sgr(c.attribute); attr = c.attribute }
                // On a row that wraps, an empty cell is written as a space so the wrap still happens (rare: a wide
                // character that didn't fit leaves the last cell empty).
                out.append(c.hiveMindsIsEmpty ? " " : t.getCharacter(for: c))
                col += max(Int(c.width), 1)
            }
            if attr != blank { out += "\u{1b}[0m"; attr = blank }
        }
        if link != nil { out += "\u{1b}]8;;\u{1b}\\" }
        return out
    }

    static func sgr(_ a: Attribute) -> String {
        var p = ["0"]
        let s = a.style
        if s.contains(.bold) { p.append("1") }
        if s.contains(.dim) { p.append("2") }
        if s.contains(.italic) { p.append("3") }
        if s.contains(.underline) { p.append("4") }
        if s.contains(.blink) { p.append("5") }
        if s.contains(.inverse) { p.append("7") }
        if s.contains(.invisible) { p.append("8") }
        if s.contains(.crossedOut) { p.append("9") }
        p += color(a.fg, base: 38)
        p += color(a.bg, base: 48)
        if let u = a.underlineColor { p += color(u, base: 58) }
        return "\u{1b}[" + p.joined(separator: ";") + "m"
    }

    private static func color(_ c: Attribute.Color, base: Int) -> [String] {
        switch c {
        case .ansi256(let n): ["\(base);5;\(n)"]
        case .trueColor(let r, let g, let b): ["\(base);2;\(r);\(g);\(b)"]
        default: []
        }
    }

    /// Cell-by-cell comparison of both buffers (characters, widths, attributes, wraps), cursor and modes.
    static func diff(_ a: Terminal, _ b: Terminal) -> [String] {
        var problems: [String] = []
        if a.cols != b.cols || a.rows != b.rows { return ["size \(a.cols)x\(a.rows) vs \(b.cols)x\(b.rows)"] }
        if a.hiveMindsModes != b.hiveMindsModes { problems.append("modes \(a.hiveMindsModes) vs \(b.hiveMindsModes)") }
        if a.currentAttribute != b.currentAttribute { problems.append("current attribute differs") }
        for (name, x, y) in [("normal", a.hiveMindsNormalBuffer, b.hiveMindsNormalBuffer), ("alt", a.hiveMindsAltBuffer, b.hiveMindsAltBuffer)] {
            if name == "alt" && !a.isCurrentBufferAlternate { continue }
            if x.hiveMindsLineCount != y.hiveMindsLineCount { problems.append("\(name): \(x.hiveMindsLineCount) vs \(y.hiveMindsLineCount) lines"); continue }
            if x.x != y.x || x.y != y.y { problems.append("\(name) cursor \(x.x),\(x.y) vs \(y.x),\(y.y)") }
            if x.scrollTop != y.scrollTop || x.scrollBottom != y.scrollBottom { problems.append("\(name) scroll region differs") }
            for row in 0..<x.hiveMindsLineCount {
                if x.hiveMindsIsWrapped(row) != y.hiveMindsIsWrapped(row) { problems.append("\(name) wrap differs at \(row)") }
                for col in 0..<a.cols {
                    let p = Position(col: col, row: row)
                    let c1 = x.getChar(atBufferRelative: p), c2 = y.getChar(atBufferRelative: p)
                    let s1 = c1.hiveMindsIsEmpty ? " " : a.getCharacter(for: c1), s2 = c2.hiveMindsIsEmpty ? " " : b.getCharacter(for: c2)
                    let l1 = c1.getPayload() as? String, l2 = c2.getPayload() as? String
                    if s1 != s2 || c1.hiveMindsIsEmpty != c2.hiveMindsIsEmpty || c1.attribute != c2.attribute || c1.width != c2.width || l1 != l2 {
                        problems.append("\(name) cell \(col),\(row): '\(c1.hiveMindsIsEmpty ? "∅" : s1)' w\(c1.width) \(c1.attribute) \(l1 ?? "") vs '\(c2.hiveMindsIsEmpty ? "∅" : s2)' w\(c2.width) \(c2.attribute) \(l2 ?? "")")
                        if problems.count > 12 { return problems }
                    }
                }
            }
        }
        return problems
    }

    static func screenText(_ t: Terminal) -> String {
        (0..<t.rows).map { t.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }.joined(separator: "\n")
    }
}
