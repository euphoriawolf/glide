import AppKit
import AVFoundation
import FoundationModels
import Speech
import SwiftUI

// MARK: - Model

final class DictationModel: ObservableObject {
    enum State { case idle, preparing, listening, finishing }
    @Published var state: State = .idle
    /// Microphone level 0...1.
    @Published var level: Float = 0
    /// Words so far: final text plus the current guess.
    @Published var text = ""
    /// A short message in the pill, for example when no text field has focus.
    @Published var notice: String?

    func flash(_ message: String) {
        notice = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.notice == message { self?.notice = nil }
        }
    }
}

// MARK: - Engine

/// Hold to talk. Audio goes to an on-device Apple speech model (macOS 26):
/// SpeechTranscriber, or DictationTranscriber for languages the new model does not cover.
/// Then voice commands, then an optional on-device clean-up pass.
/// Step timings for each dictation, in ~/Library/Logs/Glide/dictation.log.
enum DictationLog {
    private static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Glide/dictation.log")
    private static var t0 = Date()

    static func begin() { t0 = Date(); write("start") }

    static func write(_ line: String) {
        let text = String(format: "%@ +%.2fs %@\n", ISO8601DateFormatter().string(from: Date()), Date().timeIntervalSince(t0), line)
        guard let data = text.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}

final class Dictation {
    let model = DictationModel()
    /// The finished text, on the main thread.
    var onFinal: (String) -> Void = { _ in }

    private let audio = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var finalized = ""
    private var volatile = ""
    private var session = 0
    private var stopRequested = false
    private var installed: Set<String> = []
    private var startTime = Date()
    /// Text before the cursor in the target field. Primes the model and guides the clean-up.
    private var fieldText = ""

    static var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    static func requestMic(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    func start(fieldText: String = "") {
        guard model.state == .idle, Self.micAllowed else { return }
        session += 1
        let id = session
        finalized = ""
        volatile = ""
        stopRequested = false
        startTime = Date()
        self.fieldText = fieldText
        model.text = ""
        model.state = .preparing
        DictationLog.begin()
        Task { @MainActor in
            do {
                try await self.begin(id)
            } catch {
                NSLog("Glide dictation: \(error)")
                DictationLog.write("error: \(error)")
                self.teardown()
                self.model.state = .idle
            }
        }
    }

    /// Key or hand released. A very short tap with no words is a cancel.
    func stop() {
        let short = Date().timeIntervalSince(startTime) < 0.3
        DictationLog.write("stop in state \(model.state), words so far: \((finalized + volatile).count) chars")
        switch model.state {
        case .preparing:
            stopRequested = true
            if short { cancel() }
        case .listening:
            if short && finalized.isEmpty && volatile.isEmpty { cancel() } else { finish() }
        default:
            break
        }
    }

    func cancel() {
        DictationLog.write("cancel")
        session += 1
        teardown()
        model.state = .idle
    }

    @MainActor private func begin(_ id: Int) async throws {
        let module: any SpeechModule
        if let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            let t = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            module = t
            DictationLog.write("SpeechTranscriber \(locale.identifier)")
            try await install(t, key: "speech-\(locale.identifier)")
            DictationLog.write("assets ready")
            resultsTask = Task { [weak self] in
                do {
                    for try await r in t.results {
                        let s = String(r.text.characters), f = r.isFinal
                        await MainActor.run { self?.receive(s, final: f) }
                    }
                } catch {}
            }
        } else {
            let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) ?? Locale(identifier: "en-US")
            let t = DictationTranscriber(locale: locale, preset: .progressiveShortDictation)
            module = t
            DictationLog.write("DictationTranscriber \(locale.identifier)")
            try await install(t, key: "dictation-\(locale.identifier)")
            DictationLog.write("assets ready")
            resultsTask = Task { [weak self] in
                do {
                    for try await r in t.results {
                        let s = String(r.text.characters), f = r.isFinal
                        await MainActor.run { self?.receive(s, final: f) }
                    }
                } catch {}
            }
        }
        guard id == session else { return }

        let analyzer = SpeechAnalyzer(modules: [module])
        // Words the model should expect: the user's list and words already in the field.
        let words = DictationText.contextWords(field: fieldText, vocabulary: Settings.shared.vocabulary)
        if !words.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = words
            try? await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw NSError(domain: "Glide", code: 1, userInfo: [NSLocalizedDescriptionKey: "No audio format"])
        }
        try await analyzer.prepareToAnalyze(in: format)
        DictationLog.write("analyzer prepared, format \(format.sampleRate) Hz")
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.analyzer = analyzer
        self.continuation = continuation

        try await analyzer.start(inputSequence: stream)
        try startAudio(into: continuation, format: format)
        guard id == session else { return }
        model.state = .listening
        DictationLog.write("listening, mic \(audio.inputNode.outputFormat(forBus: 0).sampleRate) Hz")
        // Warm the clean-up model only once the mic is live: warming it first delayed listening by 6 s.
        if Settings.shared.cleanUp { DispatchQueue.main.async { DictationText.prewarm() } }
        if stopRequested { finish() }
    }

    private func install(_ module: any SpeechModule, key: String) async throws {
        guard !installed.contains(key) else { return }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        installed.insert(key)
    }

    private func receive(_ s: String, final: Bool) {
        DictationLog.write("\(final ? "final" : "partial"): \(s.count) chars")
        if final {
            finalized += s
            volatile = ""
        } else {
            volatile = s
        }
        model.text = (finalized + volatile).trimmingCharacters(in: .whitespaces)
    }

    private func finish() {
        let id = session
        model.state = .finishing
        stopAudio()
        continuation?.finish()
        Task { @MainActor in
            DictationLog.write("finishing")
            try? await self.analyzer?.finalizeAndFinishThroughEndOfInput()
            DictationLog.write("analyzer finalized")
            let timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.resultsTask?.cancel()
            }
            await self.resultsTask?.value
            timeout.cancel()
            guard id == self.session else { return }
            let raw = (self.finalized + self.volatile).trimmingCharacters(in: .whitespacesAndNewlines)
            DictationLog.write("results done: \(raw.count) chars")
            self.teardown()
            guard !raw.isEmpty else {
                self.model.state = .idle
                return
            }
            var text = DictationText.applyCommands(raw)
            if Settings.shared.cleanUp, let polished = await DictationText.polish(text, field: self.fieldText) {
                text = polished
            }
            guard id == self.session else { return }
            DictationLog.write("final text ready after clean-up: \(text)")
            self.model.text = text
            self.model.state = .idle
            self.onFinal(text)
        }
    }

    private func teardown() {
        stopAudio()
        continuation?.finish()
        continuation = nil
        resultsTask?.cancel()
        resultsTask = nil
        let a = analyzer
        analyzer = nil
        Task { await a?.cancelAndFinishNow() }
        model.level = 0
    }

    // MARK: Audio

    private func startAudio(into continuation: AsyncStream<AnalyzerInput>.Continuation, format: AVAudioFormat) throws {
        let input = audio.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: inFormat, to: format)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.meter(buffer)
            if let out = self.convert(buffer, to: format) { continuation.yield(AnalyzerInput(buffer: out)) }
        }
        audio.prepare()
        try audio.start()
    }

    private func stopAudio() {
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }

    private func meter(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(max(n, 1))).squareRoot()
        let level = min(1, rms * 9)
        DispatchQueue.main.async { self.model.level += (level - self.model.level) * 0.5 }
    }
}

// MARK: - Text

/// Voice commands, context words and the clean-up pass.
enum DictationText {
    /// "new line" / "next line" and "new paragraph" become line breaks. Punctuation before them stays.
    static func applyCommands(_ s: String) -> String {
        var t = s
        let rules: [(String, String)] = [
            (#"[ ,]*\b(new|next) paragraph\b[.,!?]?[ ]*"#, "\n\n"),
            (#"[ ,]*\b(new|next) line\b[.,!?]?[ ]*"#, "\n"),
        ]
        for (pattern, replacement) in rules {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        // A new line starts with a capital letter.
        let lines = t.components(separatedBy: "\n").map { line -> String in
            guard let first = line.first else { return line }
            return first.uppercased() + line.dropFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespaces)
    }

    /// Words to prime the speech model with.
    static func contextWords(field: String, vocabulary: String) -> [String] {
        var words = vocabulary.split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var seen = Set(words.map { $0.lowercased() })
        let fieldWords = field.suffix(1500).split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "-" })
        for w in fieldWords.reversed() where w.count >= 4 {
            let s = String(w)
            if seen.insert(s.lowercased()).inserted { words.append(s) }
            if words.count >= 80 { break }
        }
        return words
    }

    static var cleanUpAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// On-device clean-up with Apple Intelligence: fixes misheard words, punctuation and filler.
    /// Returns nil when the model is not available, is too slow, or changes the text too much.
    private static var warm: LanguageModelSession?

    private static func makeSession() -> LanguageModelSession {
        let keep = Settings.shared.vocabulary
        return LanguageModelSession(instructions: """
            You fix text that a speech recognizer wrote while a person dictated. Some words can be misheard, \
            for example "impute" for "input" or "their" for "there".
            Rules:
            - Fix misheard words. Use the context and the meaning of the sentence.
            - Fix punctuation and capital letters.
            - Remove filler words such as "um" and "uh", and repeated false starts.
            - Keep the person's words, meaning, tone and line breaks.
            - Write these words exactly like this: \(keep)
            - Do not add content. Do not answer questions in the text. Do not summarize.
            - Reply with the fixed text only. No quotes, no notes.
            """)
    }

    /// Loads the model while the person talks, so the clean-up starts warm.
    static func prewarm() {
        guard cleanUpAvailable else { return }
        let s = makeSession()
        s.prewarm()
        warm = s
    }

    /// Measured: a cold clean-up took 7.2 s. The text goes in as heard after this long.
    static let polishLimit = 1.2

    static func polish(_ text: String, field: String) async -> String? {
        guard cleanUpAvailable else { return nil }
        let session = warm ?? makeSession()
        warm = nil
        let prompt = field.isEmpty
            ? "Dictated text:\n\(text)"
            : "Text already in the field, for context only:\n\(field.suffix(400))\n\nDictated text to fix:\n\(text)"

        // A real race: whichever ends first wins. Cancelling the model does not stop it at once,
        // so waiting for it after the time limit was the 7 s delay.
        let out: String? = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let once = Once()
            let work = Task {
                let r = try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0))
                if once.claim() { done.resume(returning: r?.content.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            Task {
                try? await Task.sleep(for: .seconds(polishLimit))
                if once.claim() {
                    work.cancel()
                    done.resume(returning: nil)
                }
            }
        }
        guard var out, !out.isEmpty else {
            DictationLog.write("clean-up skipped: over \(polishLimit) s or empty")
            return nil
        }
        if out.hasPrefix("\"") && out.hasSuffix("\"") && out.count > 2 { out = String(out.dropFirst().dropLast()) }
        // A clean-up changes a few words. A big change means the model did something else.
        let ratio = Double(out.count) / Double(max(text.count, 1))
        guard ratio > 0.6 && ratio < 1.5 else { return nil }
        return out
    }
}

/// Lets exactly one of several racers finish a continuation.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if taken { return false }
        taken = true
        return true
    }
}

// MARK: - Hold key

/// Watches one modifier key held alone. Another key while it is down cancels.
final class HoldKey {
    var keyCode: UInt16
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}
    var onCancel: () -> Void = {}
    private var monitors: [Any] = []
    private var isDown = false

    init(keyCode: UInt16) {
        self.keyCode = keyCode
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        let key: (NSEvent) -> Void = { [weak self] _ in
            guard let self, self.isDown else { return }
            self.isDown = false
            self.onCancel()
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { key($0); return $0 }) { monitors.append(m) }
    }

    deinit { monitors.forEach { NSEvent.removeMonitor($0) } }

    private func flagsChanged(_ e: NSEvent) {
        guard e.keyCode == keyCode else {
            // Another modifier joined: this is a shortcut, not dictation.
            if isDown { isDown = false; onCancel() }
            return
        }
        let down = keyCode == 63 ? e.modifierFlags.contains(.function) : e.modifierFlags.contains(.option)
        if down && !isDown {
            isDown = true
            onDown()
        } else if !down && isDown {
            isDown = false
            onUp()
        }
    }
}

// MARK: - Insert

/// Types text into the focused field through the pasteboard, then puts the old pasteboard back.
enum TextInserter {
    static func insert(_ text: String) {
        DictationLog.write("paste into \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"): \(text.count) chars")
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pb.clearContents()
        pb.setString(text, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: down)  // V
            e?.flags = .maskCommand
            e?.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pb.clearContents()
            if !saved.isEmpty { pb.writeObjects(saved) }
        }
    }
}

// MARK: - Pill

/// Grows out of the notch while you talk: a live waveform and your words.
final class ListeningPill: NSPanel {
    init(model: DictationModel) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 420, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .popUpMenu
        ignoresMouseEvents = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        contentView = NSHostingView(rootView: PillView(model: model))
    }

    override var canBecomeKey: Bool { false }

    func placeOnPointerScreen() {
        let m = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(m, $0.frame, false) } ?? NSScreen.main
        guard let f = screen?.frame else { return }
        setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height))
        orderFrontRegardless()
    }
}

private struct PillView: View {
    @ObservedObject var model: DictationModel

    var body: some View {
        VStack(spacing: 0) {
            if let notice = model.notice, model.state == .idle {
                HStack(spacing: 8) {
                    Image(systemName: "character.cursor.ibeam")
                    Text(notice)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(minWidth: 220, minHeight: 38)
                .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 19, bottomTrailingRadius: 19))
                .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
            } else if model.state != .idle {
                HStack(spacing: 12) {
                    Waveform(level: model.level, active: model.state == .listening)
                        .frame(width: 40, height: 18)
                    if !model.text.isEmpty {
                        Text(model.text)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: 300, alignment: .leading)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 18)
                .frame(minWidth: 220, minHeight: 38)
                .background(Color.black, in: UnevenRoundedRectangle(bottomLeadingRadius: 19, bottomTrailingRadius: 19))
                .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 64)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: model.state)
        .animation(.smooth(duration: 0.25), value: model.text)
        .animation(.spring(response: 0.35, dampingFraction: 0.78), value: model.notice)
    }
}

/// Five bars that follow the voice. They breathe while the model loads.
private struct Waveform: View {
    var level: Float
    var active: Bool

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    let wobble = (sin(t * 9 + Double(i) * 1.3) + 1) / 2
                    let base = active ? Double(level) : 0.15 * (sin(t * 3 + Double(i)) + 1) / 2
                    Capsule()
                        .fill(.white)
                        .frame(width: 3, height: 4 + 14 * CGFloat(min(1, base * (0.55 + 0.45 * wobble))))
                }
            }
        }
    }
}
