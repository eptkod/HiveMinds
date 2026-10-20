import AppKit

/// The kinds of moments that make a sound. Each has its own shape so you can tell them apart without looking.
enum Cue: String, CaseIterable, Identifiable {
    case permission, question, error, done

    var id: String { rawValue }

    var label: String {
        switch self {
        case .permission: "Asks permission"
        case .question: "Asks a question"
        case .error: "Hits an error"
        case .done: "Finishes"
        }
    }

    var explainer: String {
        switch self {
        case .permission: "A doorbell ding-dong: an agent wants to run a command or edit a file and is waiting for your OK."
        case .question: "Two notes rising, like \"hm?\": an agent asked you something and is waiting for an answer."
        case .error: "A low \"uh-oh\": an agent stopped because something went wrong, such as an API error or a limit."
        case .done: "A quick rising sparkle: an agent finished its task, or a meeting finished."
        }
    }

    fileprivate var notes: [Note] {
        switch self {
        case .permission: [
            Note(freq: 659.25, at: 0, length: 0.45, decay: 0.22, timbre: .bell),   // E5
            Note(freq: 523.25, at: 0.2, length: 0.65, decay: 0.32, timbre: .bell), // C5
        ]
        case .question: [
            Note(freq: 587.33, at: 0, length: 0.2, decay: 0.1, timbre: .soft),                  // D5
            Note(freq: 783.99, at: 0.13, length: 0.45, glide: 1.12, decay: 0.24, timbre: .soft), // G5, bending up
        ]
        case .error: [
            Note(freq: 392.0, at: 0, length: 0.24, decay: 0.12, timbre: .buzz),                   // G4
            Note(freq: 277.18, at: 0.17, length: 0.5, glide: 0.97, decay: 0.2, timbre: .buzz),    // C#4, sagging
        ]
        case .done: [
            Note(freq: 523.25, at: 0, length: 0.35, decay: 0.12, timbre: .bell),    // C5
            Note(freq: 659.25, at: 0.07, length: 0.35, decay: 0.12, timbre: .bell), // E5
            Note(freq: 783.99, at: 0.14, length: 0.35, decay: 0.12, timbre: .bell), // G5
            Note(freq: 1046.5, at: 0.21, length: 0.7, decay: 0.3, timbre: .bell),   // C6
        ]
        }
    }
}

/// Plays the cues. Each one is synthesised once, on first use, into a short WAV kept in memory:
/// no sound files to ship and no audio engine left running between sounds.
@MainActor
enum Sounds {
    private static var cache: [Cue: NSSound] = [:]
    private static var lastPlayed: [Cue: Date] = [:]

    /// Plays a cue if sounds and that cue are on. `preview` plays it regardless, for the Settings buttons.
    static func play(_ cue: Cue, preview: Bool = false) {
        let d = UserDefaults.standard
        if !preview {
            guard d.object(forKey: SettingKey.soundsOn) as? Bool ?? SettingDefault.soundsOn,
                  d.object(forKey: SettingKey.sound(cue)) as? Bool ?? SettingDefault.sound else { return }
            // Several agents stopping at once make one sound, not a pile-up.
            if let last = lastPlayed[cue], Date().timeIntervalSince(last) < 1 { return }
        }
        lastPlayed[cue] = Date()
        guard let sound = cache[cue] ?? NSSound(data: wav(cue.notes)) else { return }
        cache[cue] = sound
        sound.stop()
        sound.volume = Float(d.object(forKey: SettingKey.soundVolume) as? Double ?? SettingDefault.soundVolume)
        sound.play()
    }

    private static let rate = 44_100.0

    /// Mixes the notes and wraps them as 16-bit mono WAV.
    private static func wav(_ notes: [Note]) -> Data {
        let total = notes.map { $0.at + $0.length }.max() ?? 0
        var mix = [Double](repeating: 0, count: Int(total * rate))
        for n in notes {
            let start = Int(n.at * rate)
            var phase = 0.0
            for i in 0..<Int(n.length * rate) where start + i < mix.count {
                let t = Double(i) / rate
                phase += 2 * .pi * n.freq * pow(n.glide, t / n.length) / rate
                let envelope = min(1, t / 0.006) * exp(-t / n.decay) * min(1, (n.length - t) / 0.02)
                var v = sin(phase)
                for (multiple, amount) in n.timbre.partials { v += amount * sin(phase * multiple) }
                mix[start + i] += v * envelope
            }
        }
        let peak = mix.map(abs).max() ?? 1
        let scale = peak > 0 ? 0.8 / peak : 0

        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(mix.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); put(36 + bytes)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate) * 2); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(bytes)
        for s in mix { put(Int16(max(-1, min(1, s * scale)) * Double(Int16.max))) }
        return data
    }
}

/// One tone in a cue. `glide` is how far the pitch bends by the end (1.12 is about two semitones up).
private struct Note {
    var freq: Double
    var at: Double
    var length: Double
    var glide = 1.0
    var decay: Double
    var timbre: Timbre
}

private enum Timbre {
    case bell, soft, buzz

    /// Overtones added to the plain sine: (multiple of the pitch, loudness).
    var partials: [(Double, Double)] {
        switch self {
        case .bell: [(2, 0.35), (3, 0.12), (4.2, 0.06)]
        case .soft: [(2, 0.15)]
        case .buzz: [(3, 0.3), (5, 0.15), (7, 0.07)]
        }
    }
}
