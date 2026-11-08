import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The terminal `serve` (or `pair`) runs in: single keys without Return (`p` for a new pairing code, `y`/`n` for
/// questions), with Ctrl+C still working. Questions are asked one at a time. Without a terminal (under systemd)
/// nothing is read, and questions are answered by `hiveminds-host pair` instead.
final class Console {
    let isInteractive: Bool
    private var original: termios?
    private var source: DispatchSourceRead?
    private var questions: [(id: UUID, prompt: String, answer: (Bool) -> Void)] = []
    /// Keys pressed while no question is waiting.
    var onKey: (Character) -> Void = { _ in }

    init() {
        isInteractive = isatty(0) == 1 && isatty(1) == 1
        guard isInteractive else { return }
        var t = termios()
        guard tcgetattr(0, &t) == 0 else { return }
        original = t
        // No line editing or echo, so a key arrives at once; keep ISIG so Ctrl+C is still a signal.
        t.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutableBytes(of: &t.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(0, TCSANOW, &t)
        let s = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        s.setEventHandler { [weak self] in self?.readKeys() }
        source = s
        s.resume()
    }

    /// Puts the terminal back as it was. Safe to call more than once.
    func restore() {
        guard var t = original else { return }
        tcsetattr(0, TCSANOW, &t)
        original = nil
        source?.cancel()
        source = nil
    }

    deinit { restore() }

    private func readKeys() {
        var buf = [UInt8](repeating: 0, count: 64)
        let n = read(0, &buf, buf.count)
        guard n > 0 else { return }
        for b in buf[0..<n] {
            let c = Character(UnicodeScalar(b))
            if let q = questions.first {
                let yes = c == "y" || c == "Y"
                guard yes || c == "n" || c == "N" || b == 10 || b == 13 || b == 27 else { continue }
                write(yes ? "y\n" : "n\n")
                questions.removeFirst()
                q.answer(yes)
                showNext()
            } else {
                onKey(c)
            }
        }
    }

    /// Asks a yes/no question (default no). Returns an id to withdraw it.
    @discardableResult
    func ask(_ prompt: String, _ answer: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        questions.append((id, prompt, answer))
        if questions.count == 1 { showNext() }
        return id
    }

    /// Takes a question back (it was answered elsewhere, or timed out), telling the person why.
    func withdraw(_ id: UUID, note: String) {
        guard let i = questions.firstIndex(where: { $0.id == id }) else { return }
        questions.remove(at: i)
        if i == 0 {
            write("\n" + note + "\n")
            showNext()
        }
    }

    /// Withdraws every question, answering each no.
    func cancelAll() {
        let all = questions
        questions = []
        for q in all { q.answer(false) }
    }

    var hasQuestion: Bool { !questions.isEmpty }

    private func showNext() {
        guard let q = questions.first else { return }
        write(q.prompt + " ")
    }

    func write(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }
}
