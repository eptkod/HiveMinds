import AppKit
import AVFoundation
import Observation
import SwiftTerm
import SwiftUI

/// The key you hold (or tap) to dictate. Only works while HiveMinds is the app in front.
enum VoiceKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, function

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption: "Right Option (⌥)"
        case .rightCommand: "Right Command (⌘)"
        case .function: "Fn / Globe (🌐)"
        }
    }

    /// Short name for the pill.
    var short: String {
        switch self {
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        case .function: "🌐"
        }
    }

    var explainer: String {
        switch self {
        case .rightOption: "The Option key on the right of the space bar. The left one still works as usual."
        case .rightCommand: "The Command key on the right of the space bar. The left one still works as usual."
        case .function: "Set \"Press 🌐 key to\" to \"Do Nothing\" in System Settings > Keyboard, or macOS will also react to it."
        }
    }

    fileprivate var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .function: 63
        }
    }

    fileprivate var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: .option
        case .rightCommand: .command
        case .function: .function
        }
    }
}

/// Push-to-talk dictation into the terminal or text field you're in. Off unless turned on in
/// Settings > Voice; when off, nothing is listening, not even the key.
@MainActor @Observable
final class Dictation {
    static let shared = Dictation()

    enum Phase: Equatable { case idle, listening, working, message(String) }
    private(set) var phase = Phase.idle
    /// Loudness of the last bit of audio, 0 to 1, while listening.
    private(set) var level: Double = 0
    /// The last few things you said, newest first, so text that didn't land can be typed again or copied.
    /// Memory only: never saved, and never put on the clipboard unless you ask.
    private(set) var recent: [String] = []

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private let recorder = MicRecorder()
    @ObservationIgnored private weak var target: NSResponder?
    @ObservationIgnored private var keyDownAt: Date?
    @ObservationIgnored private var keyUsedAsModifier = false
    /// Key + Space locks listening on, so you can let go and keep talking. Tapping the key again finishes.
    @ObservationIgnored private var handsFree = false
    @ObservationIgnored private var messageClear: DispatchWorkItem?
    /// Goes up on every cancel, so text from a cancelled recording is dropped when it arrives.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private lazy var hud = DictationHUD()

    private var transcriber: Transcriber {
        VoiceDefaults.engine == .whisper ? WhisperHelper.shared : AppleTranscriber()
    }

    /// Starts or stops listening for the key, to match the setting. Called at launch and when settings change.
    func refresh() {
        if VoiceDefaults.enabled {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
                self?.handle(event) ?? event
            }
        } else {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            recent = []
            cancel()
            WhisperHelper.shared.stop()
        }
    }

    /// A short status line on the pill, e.g. while macOS fetches a language.
    func note(_ text: String) {
        if phase == .working { hud.show(text: text, busy: true) }
    }

    /// Types the last dictation again where the cursor is now. Uses no clipboard.
    func retype() {
        guard let text = recent.first, phase != .listening, phase != .working else { return }
        if !Self.insert(text, into: NSApp.keyWindow?.firstResponder) {
            show("Click into a terminal or text field, then press ⌥⌘V.")
        }
    }

    /// Puts a dictation on the clipboard. Only ever runs when you pick it.
    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show("Copied to the clipboard")
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let key = VoiceDefaults.key
        if event.type == .keyDown {
            // Escape cancels while listening or writing it down, and nothing gets typed.
            if event.keyCode == 53 && (phase == .listening || phase == .working) {
                keyDownAt = nil
                cancel()
                return nil
            }
            // Space while holding our key: keep listening after you let go, like Wispr Flow's hands-free mode.
            // In tap mode it starts listening too. The space isn't typed.
            if event.keyCode == 49 && keyDownAt != nil {
                if !handsFree {
                    if phase != .listening { begin() }
                    guard phase == .listening else { return nil }
                    handsFree = true
                    keyUsedAsModifier = true
                    hud.show(text: "Hands-free · tap \(key.short) to finish · Esc to cancel", busy: false, listening: true)
                }
                return nil
            }
            if phase == .listening {
                // Another key while holding ours means it's being used as a modifier, e.g. ⌥-letter.
                if keyDownAt != nil { keyUsedAsModifier = true; if VoiceDefaults.holdToTalk { cancel() } }
            } else if keyDownAt != nil {
                keyUsedAsModifier = true
            }
            return event
        }
        guard event.keyCode == key.keyCode else { return event }
        let others = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([key.flag, .capsLock, .function])
        if event.modifierFlags.contains(key.flag) {
            guard others.isEmpty else { return event }
            if handsFree {
                // Tapping the key again ends a hands-free recording.
                handsFree = false
                keyDownAt = nil
                if phase == .listening { finish() }
                return event
            }
            keyDownAt = Date()
            keyUsedAsModifier = false
            if VoiceDefaults.holdToTalk && phase != .listening { begin() }
        } else if let downAt = keyDownAt {
            keyDownAt = nil
            if handsFree { return event }
            if VoiceDefaults.holdToTalk {
                if phase == .listening { finish() }
            } else if !keyUsedAsModifier && Date().timeIntervalSince(downAt) < 0.5 {
                phase == .listening ? finish() : begin()
            }
        }
        return event
    }

    private func begin() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.show(granted ? "Microphone on. Press the key again to talk." : "Dictation needs the microphone. Turn it on in System Settings > Privacy & Security > Microphone.")
                }
            }
            return
        default:
            show("Dictation needs the microphone. Turn it on in System Settings > Privacy & Security > Microphone.")
            return
        }
        target = NSApp.keyWindow?.firstResponder
        do {
            try recorder.start { [weak self] level in
                Task { @MainActor in self?.level = level }
            }
        } catch {
            show("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }
        transcriber.warmUp()
        messageClear?.cancel()
        phase = .listening
        hud.show(text: "Listening · Esc to cancel", busy: false, listening: true)
    }

    private func finish() {
        handsFree = false
        let samples = recorder.stop()
        level = 0
        // Under a third of a second, or nothing louder than room noise: don't guess at words.
        let loudest = samples.lazy.map(abs).max() ?? 0
        guard samples.count > 16_000 / 3, loudest > 0.02 else {
            phase = .idle
            hud.hide()
            return
        }
        phase = .working
        hud.show(text: "Writing it down…", busy: true)
        let target = self.target
        let engine = transcriber
        let generation = self.generation
        Task {
            do {
                let text = try await engine.transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
                guard generation == self.generation else { return }
                // If you've started talking again, type this anyway but leave the pill to the new recording.
                let done = { if self.phase == .working { self.phase = .idle; self.hud.hide() } }
                if text.isEmpty || Self.isNoise(text) {
                    done()
                    return
                }
                // Kept before typing, since a terminal that's still starting can swallow it without telling us.
                recent = Array(([text] + recent).prefix(5))
                if Self.insert(text, into: target) {
                    done()
                } else if phase == .working {
                    show("Didn't land anywhere. Click where it goes and press ⌥⌘V.")
                }
            } catch {
                if generation == self.generation && phase == .working { show(error.localizedDescription) }
            }
        }
    }

    private func cancel() {
        handsFree = false
        guard phase == .listening || phase == .working else { return }
        generation += 1
        _ = recorder.stop()
        level = 0
        phase = .idle
        hud.hide()
    }

    private func show(_ message: String) {
        phase = .message(message)
        hud.show(text: message, busy: false)
        messageClear?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, case .message = self.phase else { return }
            self.phase = .idle
            self.hud.hide()
        }
        messageClear = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: item)
    }

    /// Whisper sometimes "hears" these in silence or background noise.
    private static func isNoise(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return t.isEmpty || ["blank_audio", "silence", "music", "thank you", "you"].contains(t)
            || (text.hasPrefix("[") && text.hasSuffix("]")) || (text.hasPrefix("(") && text.hasSuffix(")"))
    }

    /// Types the text where the cursor was when you started talking. Terminals get it as a paste,
    /// without pressing Return, so you can read it over first.
    private static func insert(_ text: String, into responder: NSResponder?) -> Bool {
        if let term = responder as? TerminalView, term.window != nil {
            term.send(txt: term.getTerminal().bracketedPasteMode ? "\u{1b}[200~" + text + "\u{1b}[201~" : text)
            return true
        }
        if let field = responder as? NSTextView, field.window != nil, field.isEditable {
            let range = field.selectedRange()
            let before = range.location > 0 ? (field.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) : " "
            let spaced = before.rangeOfCharacter(from: .whitespacesAndNewlines) == nil ? " " + text : text
            field.insertText(spaced, replacementRange: range)
            return true
        }
        return false
    }
}

// MARK: Microphone

/// Records from the default microphone into 16 kHz mono samples, in memory only.
/// The audio engine runs only between start and stop, so it costs nothing when you aren't talking.
private final class MicRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    func start(level: @escaping @Sendable (Double) -> Void) throws {
        lock.withLock { samples = [] }
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, let converter = AVAudioConverter(from: native, to: Self.format) else {
            throw DictationError("No microphone found.")
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16_000 / native.sampleRate) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            let chunk = UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))
            self.lock.withLock { self.samples.append(contentsOf: chunk) }
            let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(max(chunk.count, 1)))
            level(min(Double(rms) * 8, 1))
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() -> [Float] {
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        return lock.withLock { let s = samples; samples = []; return s }
    }
}

// MARK: Pill

/// A small pill near the bottom of the window while you talk. It never takes focus or clicks,
/// so the text still goes where your cursor is.
@MainActor
private final class DictationHUD {
    private let model = HUDModel()
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = true
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.contentView = NSHostingView(rootView: DictationPill(model: model))
        return p
    }()

    func show(text: String, busy: Bool, listening: Bool = false) {
        model.text = text
        model.busy = busy
        model.listening = listening
        let anchor = (NSApp.keyWindow ?? NSApp.mainWindow)?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.minY + 36))
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}

@MainActor @Observable
private final class HUDModel {
    var text = ""
    var busy = false
    var listening = false
}

private struct DictationPill: View {
    let model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            if model.busy {
                ProgressView().controlSize(.small)
            } else if model.listening {
                LevelDot()
            } else {
                Image(systemName: "mic.slash").foregroundStyle(.secondary)
            }
            Text(model.text)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular.tint(.black.opacity(0.45)), in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(.dark)
    }
}

/// A red dot that grows with your voice, so you can see the microphone is hearing you.
private struct LevelDot: View {
    var body: some View {
        let level = Dictation.shared.level
        Circle()
            .fill(.red)
            .frame(width: 10, height: 10)
            .scaleEffect(1 + level * 0.8)
            .animation(.easeOut(duration: 0.08), value: level)
            .frame(width: 18, height: 18)
    }
}
