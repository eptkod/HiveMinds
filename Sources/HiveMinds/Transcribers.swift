import AVFoundation
import CryptoKit
import Foundation
import Observation
import Speech
import SwiftUI

/// Turns a clip of 16 kHz mono audio into text. Everything runs on this Mac.
protocol Transcriber {
    /// Gets ready before the clip ends (loads a model), so the wait after you let go is short.
    func warmUp()
    func transcribe(_ samples: [Float]) async throws -> String
}

struct DictationError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Which speech engine dictation uses.
enum VoiceEngine: String, CaseIterable, Identifiable {
    case apple, whisper

    var id: String { rawValue }

    var label: String {
        switch self {
        case .apple: "Apple (built in)"
        case .whisper: "Whisper (local model)"
        }
    }

    var explainer: String {
        switch self {
        case .apple: "macOS's own on-device speech model. Nothing extra to install; macOS fetches the language once if it needs to."
        case .whisper: "OpenAI's Whisper model, run by a small helper inside HiveMinds. Better with code words and the words you list below. Download a model to use it."
        }
    }
}

/// The language you speak. "auto" follows the Mac's language.
enum VoiceLanguage {
    static let choices: [(code: String, label: String)] = [
        ("auto", "Same as this Mac"), ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"),
        ("it", "Italian"), ("pt", "Portuguese"), ("nl", "Dutch"), ("ja", "Japanese"), ("zh", "Chinese"), ("ko", "Korean"),
    ]

    static func resolved(_ code: String) -> String {
        code == "auto" ? (Locale.current.language.languageCode?.identifier ?? "en") : code
    }
}

/// The dictation settings as plain values, for code outside a view.
enum VoiceDefaults {
    private static var d: UserDefaults { .standard }
    static var enabled: Bool { d.object(forKey: SettingKey.voiceOn) as? Bool ?? SettingDefault.voiceOn }
    static var engine: VoiceEngine { VoiceEngine(rawValue: d.string(forKey: SettingKey.voiceEngine) ?? "") ?? .apple }
    static var key: VoiceKey { VoiceKey(rawValue: d.string(forKey: SettingKey.voiceKey) ?? "") ?? .rightOption }
    static var holdToTalk: Bool { d.object(forKey: SettingKey.voiceHold) as? Bool ?? SettingDefault.voiceHold }
    static var language: String { VoiceLanguage.resolved(d.string(forKey: SettingKey.voiceLanguage) ?? SettingDefault.voiceLanguage) }
    static var model: WhisperModel { WhisperModel.all.first { $0.id == d.string(forKey: SettingKey.voiceModel) } ?? WhisperModel.all[0] }
    /// Names and jargon to listen for, e.g. "SwiftUI, HiveMinds, Store.swift".
    static var vocabulary: [String] {
        (d.string(forKey: SettingKey.voiceVocabulary) ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

// MARK: Apple

/// macOS 26's on-device SpeechAnalyzer. No download from us; macOS keeps the language model.
final class AppleTranscriber: Transcriber {
    func warmUp() {}

    func transcribe(_ samples: [Float]) async throws -> String {
        guard SpeechTranscriber.isAvailable else { throw DictationError("Apple's speech engine isn't available on this Mac. Try Whisper in Settings > Voice.") }
        let wanted = Locale(identifier: VoiceDefaults.language)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw DictationError("Apple's speech engine doesn't support \(wanted.localizedString(forIdentifier: wanted.identifier) ?? wanted.identifier).")
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await MainActor.run { Dictation.shared.note("Getting Apple's speech model ready…") }
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let words = VoiceDefaults.vocabulary
        if !words.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = words
            try await analyzer.setContext(context)
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? Self.clipFormat
        let buffer = try Self.buffer(samples, in: format)
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        async let text: String = transcriber.results.reduce("") { $0 + String($1.text.characters) }
        try await analyzer.start(inputSequence: input)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await text
    }

    private static let clipFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!

    /// The clip as one buffer in the format the analyzer wants.
    private static func buffer(_ samples: [Float], in format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let clip = AVAudioPCMBuffer(pcmFormat: clipFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw DictationError("Couldn't prepare the recording.")
        }
        clip.frameLength = clip.frameCapacity
        samples.withUnsafeBufferPointer { clip.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if format == clipFormat { return clip }
        guard let converter = AVAudioConverter(from: clipFormat, to: format),
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16_000) + 1024)
        else { throw DictationError("Couldn't prepare the recording.") }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return clip
        }
        if let error { throw error }
        return out
    }
}

// MARK: Whisper

/// A Whisper model you can download. Pinned to a file and checksum so what's run is what was checked.
struct WhisperModel: Identifiable, Hashable {
    let id: String
    let label: String
    let megabytes: Int
    let sha256: String
    let englishOnly: Bool

    static let all = [
        WhisperModel(id: "base.en", label: "Base, English", megabytes: 148,
                     sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002", englishOnly: true),
        WhisperModel(id: "small.en", label: "Small, English (more accurate)", megabytes: 488,
                     sha256: "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d", englishOnly: true),
        WhisperModel(id: "base", label: "Base, many languages", megabytes: 148,
                     sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", englishOnly: false),
    ]

    var url: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-\(id).bin")! }
    var file: URL { WhisperModels.folder.appendingPathComponent("ggml-\(id).bin") }
}

/// Downloads, checks and removes Whisper models in Application Support/HiveMinds/Voice.
@MainActor @Observable
final class WhisperModels: NSObject, URLSessionDownloadDelegate {
    static let shared = WhisperModels()
    nonisolated static let folder: URL = {
        let support = ProcessInfo.processInfo.environment["HIVEMINDS_SUPPORT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("HiveMinds", isDirectory: true)
        return support.appendingPathComponent("Voice", isDirectory: true)
    }()

    /// Download progress from 0 to 1, by model id, while a download runs.
    private(set) var progress: [String: Double] = [:]
    private(set) var failure: [String: String] = [:]
    /// Bumped when files change, so views re-check what's installed.
    private(set) var revision = 0
    @ObservationIgnored private var tasks: [Int: WhisperModel] = [:]
    @ObservationIgnored private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    /// The helper ships inside the app. A build made with HIVEMINDS_NO_WHISPER=1 leaves it out.
    nonisolated static var helper: URL? { Bundle.main.url(forAuxiliaryExecutable: "hiveminds-whisper") }

    func isInstalled(_ model: WhisperModel) -> Bool {
        _ = revision
        return FileManager.default.fileExists(atPath: model.file.path)
    }

    var installedBytes: Int64 {
        _ = revision
        return WhisperModel.all.reduce(0) { sum, m in
            sum + ((try? FileManager.default.attributesOfItem(atPath: m.file.path)[.size] as? Int64) ?? 0)
        }
    }

    func download(_ model: WhisperModel) {
        guard progress[model.id] == nil else { return }
        failure[model.id] = nil
        progress[model.id] = 0
        let task = session.downloadTask(with: model.url)
        tasks[task.taskIdentifier] = model
        task.resume()
    }

    func cancel(_ model: WhisperModel) {
        session.getAllTasks { all in
            Task { @MainActor in
                for t in all where self.tasks[t.taskIdentifier] == model { t.cancel() }
            }
        }
    }

    func remove(_ model: WhisperModel) {
        WhisperHelper.shared.stop()
        try? FileManager.default.removeItem(at: model.file)
        revision += 1
    }

    /// Deletes every downloaded model and the folder they're in.
    func removeAll() {
        WhisperHelper.shared.stop()
        try? FileManager.default.removeItem(at: Self.folder)
        revision += 1
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        MainActor.assumeIsolated {
            guard let model = tasks[id] else { return }
            let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(model.megabytes) * 1_000_000
            progress[model.id] = min(Double(totalBytesWritten) / total, 1)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this returns, so move it before checking it.
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: staged)
        let id = downloadTask.taskIdentifier
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        MainActor.assumeIsolated {
            guard let model = tasks[id] else { return }
            Task.detached {
                let ok = status == 200 && Self.sha256(of: staged) == model.sha256
                if ok {
                    try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: model.file)
                    try? FileManager.default.moveItem(at: staged, to: model.file)
                } else {
                    try? FileManager.default.removeItem(at: staged)
                }
                await MainActor.run {
                    if !ok { self.failure[model.id] = "The download didn't match its checksum, so it was deleted. Try again." }
                    self.progress[model.id] = nil
                    self.revision += 1
                }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskIdentifier
        MainActor.assumeIsolated {
            guard let model = tasks.removeValue(forKey: id) else { return }
            // A finished download is handled above; this only reports failures and cancels.
            guard let error else { return }
            progress[model.id] = nil
            if (error as NSError).code != NSURLErrorCancelled { failure[model.id] = "Download failed: \(error.localizedDescription)" }
        }
    }

    nonisolated private static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Runs whisper.cpp in a helper process, so a crash or the C++ build can't take the app down with it.
/// The helper starts when you begin talking, stays warm for a few minutes after, then exits on a
/// single timer. Audio goes to it over a pipe; nothing is written to disk.
final class WhisperHelper: Transcriber, @unchecked Sendable {
    static let shared = WhisperHelper()
    private static let keepWarm: TimeInterval = 180

    private let queue = DispatchQueue(label: "hiveminds.whisper")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var waitingForReady = false
    /// What the running helper was started with. A settings change restarts it.
    private var config: [String] = []
    private var idleStop: DispatchWorkItem?

    func warmUp() {
        queue.async { _ = try? self.ensureRunning() }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await withCheckedThrowingContinuation { done in
            queue.async {
                do {
                    try self.ensureRunning()
                    if self.waitingForReady {
                        guard self.readLine() == "ready" else { throw self.died() }
                        self.waitingForReady = false
                    }
                    var count = UInt32(samples.count).littleEndian
                    var packet = Data(bytes: &count, count: 4)
                    samples.withUnsafeBufferPointer { packet.append(UnsafeBufferPointer(start: $0.baseAddress, count: $0.count)) }
                    try self.input?.write(contentsOf: packet)
                    guard let line = self.readLine() else { throw self.died() }
                    self.scheduleStop()
                    done.resume(returning: line.trimmingCharacters(in: .whitespaces))
                } catch {
                    self.stopNow()
                    done.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async { self.stopNow() }
    }

    // Everything below runs on `queue`.

    private func ensureRunning() throws {
        idleStop?.cancel()
        let model = VoiceDefaults.model
        let language = model.englishOnly ? "en" : VoiceDefaults.language
        let wanted = [model.file.path, language, VoiceDefaults.vocabulary.joined(separator: ", ")]
        if process?.isRunning == true && wanted == config { return }
        stopNow()
        guard let helper = WhisperModels.helper else {
            throw DictationError("This copy of HiveMinds was built without the Whisper helper. Use Apple's engine, or rebuild with scripts/build-app.sh.")
        }
        guard FileManager.default.fileExists(atPath: model.file.path) else {
            throw DictationError("The Whisper model isn't downloaded yet. Get it in Settings > Voice.")
        }
        let p = Process()
        p.executableURL = helper
        p.arguments = wanted
        let toHelper = Pipe(), fromHelper = Pipe()
        p.standardInput = toHelper
        p.standardOutput = fromHelper
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        input = toHelper.fileHandleForWriting
        output = fromHelper.fileHandleForReading
        buffer = Data()
        waitingForReady = true
        config = wanted
        scheduleStop()
    }

    private func readLine() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                return line
            }
            // `availableData` returns as soon as anything arrives; `read(upToCount:)` waits for the full count.
            guard let chunk = output?.availableData, !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }

    private func died() -> DictationError {
        DictationError("The Whisper helper stopped unexpectedly. Try again, or pick another model in Settings > Voice.")
    }

    private func scheduleStop() {
        idleStop?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.stopNow() }
        idleStop = item
        queue.asyncAfter(deadline: .now() + Self.keepWarm, execute: item)
    }

    private func stopNow() {
        idleStop?.cancel()
        idleStop = nil
        try? input?.close()
        process?.terminate()
        process = nil
        input = nil
        output = nil
        config = []
    }
}

#if DEBUG
/// Debug builds only: `HIVEMINDS_TEST_DICTATION=/path/clip.wav` runs a recording through both engines,
/// the way dictation does after you let go of the key, prints what each heard and how long it took, then quits.
enum DictationTest {
    @MainActor static func runIfRequested() -> Bool {
        func log(_ s: String) { print(s); fflush(stdout) }
        // `HIVEMINDS_TEST_DICTATION_SNAP=/path/prefix` saves a picture of Settings > Voice instead.
        if let prefix = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_DICTATION_SNAP"] {
            let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 540, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: VoiceSettings().frame(width: 540).preferredColorScheme(.dark).background(.black))
            window.makeKeyAndOrderFront(nil)
            Task {
                try? await Task.sleep(for: .seconds(2))
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: prefix + "-voice.png"))
                }
                log("DICTATION-SNAP done"); exit(0)
            }
            return true
        }
        guard let path = ProcessInfo.processInfo.environment["HIVEMINDS_TEST_DICTATION"] else { return false }
        Task {
            do {
                let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
                guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
                else { log("DICTATION-FAIL needs a 16 kHz mono file"); exit(1) }
                try file.read(into: buffer)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
                let models = WhisperModels.shared
                if WhisperModels.helper != nil && !models.isInstalled(VoiceDefaults.model) {
                    let start = Date()
                    models.download(VoiceDefaults.model)
                    while models.progress[VoiceDefaults.model.id] != nil { try await Task.sleep(for: .milliseconds(500)) }
                    log(String(format: "DICTATION-download %.1fs installed=%@ %@", Date().timeIntervalSince(start),
                               "\(models.isInstalled(VoiceDefaults.model))", models.failure[VoiceDefaults.model.id] ?? ""))
                }
                var engines: [(String, Transcriber)] = [("apple", AppleTranscriber())]
                if WhisperModels.helper != nil && WhisperModels.shared.isInstalled(VoiceDefaults.model) {
                    engines.append(("whisper-cold", WhisperHelper.shared))
                    engines.append(("whisper-warm", WhisperHelper.shared))
                }
                for (name, engine) in engines {
                    let start = Date()
                    let text = try await engine.transcribe(samples)
                    log(String(format: "DICTATION-%@ %.2fs %@", name, Date().timeIntervalSince(start), text))
                }
                WhisperHelper.shared.stop()
                exit(0)
            } catch {
                log("DICTATION-FAIL \(error.localizedDescription)"); exit(1)
            }
        }
        return true
    }
}
#endif
