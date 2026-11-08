// Added for HiveMinds: read-only access to terminal state that a screen snapshot needs.
// Everything here reads existing state; nothing changes behaviour.
import Foundation

/// The terminal state a snapshot must restore, beyond the cells themselves.
public struct HiveMindsModes: Equatable {
    public var cursorHidden: Bool
    public var applicationCursor: Bool
    public var applicationKeypad: Bool
    public var bracketedPaste: Bool
    public var originMode: Bool
    public var wraparound: Bool
    public var reverseWraparound: Bool
    public var insertMode: Bool
    public var sendFocus: Bool
    public var mouseMode: Terminal.MouseMode
    /// 1006 for SGR, 1005 for UTF-8, 1015 for urxvt, 1016 for SGR pixels, nil for the default X10 encoding.
    public var mouseEncodingMode: Int?
    public var alternateScreen: Bool
}

extension Terminal {
    public var hiveMindsModes: HiveMindsModes {
        let encoding: Int?
        switch mouseProtocol {
        case .x10: encoding = nil
        case .utf8: encoding = 1005
        case .sgr: encoding = 1006
        case .urxvt: encoding = 1015
        case .sgrPixel: encoding = 1016
        }
        return HiveMindsModes(cursorHidden: cursorHidden, applicationCursor: applicationCursor,
                              applicationKeypad: applicationKeypad, bracketedPaste: bracketedPasteMode,
                              originMode: originMode, wraparound: wraparound, reverseWraparound: reverseWraparound,
                              insertMode: insertMode, sendFocus: sendFocus, mouseMode: mouseMode,
                              mouseEncodingMode: encoding, alternateScreen: isCurrentBufferAlternate)
    }

    /// The normal (not alternate) screen buffer, which holds the scrollback.
    public var hiveMindsNormalBuffer: Buffer { normalBuffer }
    /// The alternate screen buffer used by full-screen programs.
    public var hiveMindsAltBuffer: Buffer { altBuffer }
}

extension Buffer {
    /// How many lines the buffer holds: scrollback plus the screen.
    public var hiveMindsLineCount: Int { lines.count }
    /// How many of those lines are scrollback above the screen.
    public var hiveMindsScrollbackCount: Int { yBase }
    /// Whether the line at a buffer-relative row continues the line above it (it was wrapped, not ended).
    public func hiveMindsIsWrapped(_ row: Int) -> Bool {
        guard row >= 0 && row < lines.count else { return false }
        return lines[row].isWrapped
    }
}

extension CharData {
    /// Whether the cell was never written (as opposed to holding a space).
    public var hiveMindsIsEmpty: Bool { code == 0 }
}
