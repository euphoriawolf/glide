import AVFoundation
import GlideCore
import GlideVision
import Vision

struct TrackingSnapshot {
    var mode: GestureMode
    var enabled: Bool
    /// 0...1 toward pausing or resuming with a held palm.
    var wakeProgress: Double
    /// Joints of the hand that drives the pointer, Vision coordinates.
    var joints: Joints
    /// Joints of hands that Glide ignores.
    var others: [Joints]
    var chirality: VNChirality
    /// Palm of the primary hand, Vision coordinates (not mirrored). Nil when no hand is seen.
    var palm: CGPoint?
    /// Camera image width divided by height.
    var aspect: Double
    /// 0 with the fingers apart, 1 at the click distance.
    var pinchProgress: Double
    var pinchHeld: Double
    /// The pinch uses the middle finger: it will right-click.
    var middlePinch: Bool
    var swipeProgress: Double
    var clicks: Int
    var rightClicks: Int
    var swipes: Int
    var boostEV: Double
    var fps: Double
}

/// Which hand drives the pointer. Stored as an Int.
enum PrimaryHand: Int, Hashable {
    case either = 0, left = 1, right = 2

    var chirality: VNChirality {
        switch self {
        case .either: .unknown
        case .left: .left
        case .right: .right
        }
    }

    init(_ c: VNChirality) {
        switch c {
        case .left: self = .left
        case .right: self = .right
        default: self = .either
        }
    }
}

/// Camera -> HandReader (Vision) -> gesture engine -> pointer events.
final class Pipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onSnapshot: ((TrackingSnapshot) -> Void)?
    /// Called on the main thread for clicks, swipes and talk start and end.
    var onAction: ((GestureAction) -> Void)?
    private(set) var isRunning = false

    private let queue = DispatchQueue(label: "glide.capture", qos: .userInteractive)
    private let reader = HandReader()
    private let engine = GestureEngine()
    private let pointer = PointerOutput()

    // Owned by `queue`.
    private var acceleration = PointerAcceleration()
    private var naturalScrolling = true
    private var enabled = true
    private var practice = false
    private var lastFrameTime: Double?
    private var fps = 0.0
    private var recorder: SessionRecorder?
    /// The playground has the swipe: it changes its own desktops instead of the real ones.
    private var swipesToApp = false
    /// For the session log: the last palm seen, and whether a hand is in view.
    private var lastPalm: CGPoint?
    private var handInView = false
    /// Scroll momentum after the hand opens, in points per second. Like a trackpad flick.
    private var coast = Vec2.zero
    private var recentScroll: [(t: Double, p: Vec2)] = []
    private var lastMode = GestureMode.idle
    /// Pointer moves posted in the last half second, in pixels. An undo replays them backward.
    private var posted: [(t: Double, p: Vec2)] = []

    func start() -> Bool {
        if isRunning { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }

        session.beginConfiguration()
        if session.canSetSessionPreset(.vga640x480) { session.sessionPreset = .vga640x480 }
        guard session.canAddInput(input) else { session.commitConfiguration(); return false }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { session.commitConfiguration(); return false }
        session.addOutput(output)
        session.commitConfiguration()

        isRunning = true
        queue.async { self.session.startRunning() }
        return true
    }

    /// The menu and shortcut pause the same way the held palm does, so the palm can wake Glide again.
    func setEnabled(_ on: Bool) {
        queue.async {
            let actions = self.engine.setPaused(!on)
            self.apply(actions, dt: 0, at: self.lastFrameTime ?? 0)
            DispatchQueue.main.async { actions.forEach { self.onAction?($0) } }
        }
    }

    /// Practice: gestures are recognized but no events are posted.
    func setPractice(_ on: Bool) {
        queue.async {
            if on { self.endGestures() }
            self.practice = on
        }
    }

    func apply(_ s: Settings) {
        let speed = s.trackingSpeed, scroll = s.scrollSpeed, natural = s.naturalScrolling
        let pinch = s.pinchDistance, boost = s.lowLightBoost, hand = s.primaryHand.chirality
        queue.async {
            self.acceleration.speed = speed
            self.acceleration.scrollSpeed = scroll
            self.naturalScrolling = natural
            self.engine.config.pinchOn = pinch
            self.engine.config.pinchOff = pinch + GestureConfig.releaseGap
            self.reader.lowLightBoost = boost
            self.reader.primary = hand
        }
    }

    // MARK: - Test session

    /// Starts writing camera video and prompt labels to a new session folder.
    func startSession() -> URL? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Glide")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let folder = dir.appendingPathComponent("session-\(stamp)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let r = SessionRecorder(folder: folder) else { return nil }
        queue.async { self.recorder = r }
        return folder
    }

    func setSessionLabel(_ label: String?) {
        queue.async { self.recorder?.label = label }
    }

    /// Adds an event to the session's events.json, stamped with the time of the latest camera frame.
    func logEvent(_ event: [String: Any]) {
        queue.async { self.recorder?.log(event) }
    }

    func setSwipesToApp(_ on: Bool) {
        queue.async { self.swipesToApp = on }
    }

    func stopSession(_ done: @escaping () -> Void) {
        queue.async {
            guard let r = self.recorder else {
                DispatchQueue.main.async(execute: done)
                return
            }
            self.recorder = nil
            r.finish { DispatchQueue.main.async(execute: done) }
        }
    }

    /// Ends an open drag or talk, and tells the app.
    private func endGestures() {
        let actions = engine.reset()
        apply(actions, dt: 0, at: lastFrameTime ?? 0)
        DispatchQueue.main.async { actions.forEach { self.onAction?($0) } }
    }

    // MARK: - Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let t = time.seconds
        let dt = lastFrameTime.map { t - $0 } ?? 0
        lastFrameTime = t
        if dt > 0 { fps += (1 / dt - fps) * 0.1 }

        recorder?.append(pixels, at: time)
        let reading = reader.read(pixels, time: t)

        var actions: [GestureAction] = []
        actions = engine.update(reading.frame, now: t)
        if !practice {
            apply(actions, dt: dt, at: t)
            momentum(dt: dt, at: t)
        }
        lastMode = engine.mode
        enabled = !engine.paused
        // Hand in and out of view, with where it was (Vision coordinates, 0 to 1, not mirrored).
        if let recorder {
            let inView = reading.palm != nil
            if inView != handInView {
                let p = inView ? reading.palm : lastPalm
                recorder.log(["source": "glide", "kind": inView ? "handFound" : "handLost",
                              "x": Double(p?.x ?? -1), "y": Double(p?.y ?? -1)])
                handInView = inView
            }
            if let p = reading.palm { lastPalm = p }
        }
        // What Glide did, frame-exact, beside what the playground saw.
        if let recorder {
            for a in actions {
                switch a {
                case .move, .undo, .scroll: break
                default: recorder.log(["source": "glide", "kind": "\(a)"])
                }
            }
        }

        let snapshot = TrackingSnapshot(
            mode: engine.mode, enabled: enabled, wakeProgress: engine.wakeProgress, joints: reading.joints, others: reading.others,
            chirality: reading.chirality, palm: reading.palm, aspect: reading.aspect,
            pinchProgress: engine.pinchProgress, pinchHeld: engine.pinchHeld, middlePinch: engine.middlePinch, swipeProgress: engine.flingProgress,
            clicks: engine.clicks, rightClicks: engine.rightClicks, swipes: engine.swipes,
            boostEV: reading.boostEV, fps: fps)
        let feedback = actions.filter {
            switch $0 {
            case .click, .rightClick, .press, .release, .swipe, .talkStart, .talkEnd, .pause: return true
            default: return false
            }
        }
        DispatchQueue.main.async {
            self.onSnapshot?(snapshot)
            feedback.forEach { self.onAction?($0) }
        }
    }

    /// When a grab ends with the hand still moving, the page coasts and slows, as after a trackpad flick.
    private func momentum(dt: Double, at t: Double) {
        recentScroll.removeAll { t - $0.t > 0.12 }
        if lastMode == .grab && engine.mode != .grab {
            let span = max(0.05, (recentScroll.last?.t ?? t) - (recentScroll.first?.t ?? t))
            let v = recentScroll.reduce(Vec2.zero) { $0 + $1.p } * (1 / span)
            coast = v.length > 300 ? v : .zero   // a flick, not a slow stop
            recentScroll.removeAll()
        }
        guard coast != .zero else { return }
        // A new pinch, grab or two fingers takes over.
        if engine.mode != .hover && engine.mode != .idle {
            coast = .zero
            return
        }
        let step = coast * min(dt, 0.05)
        pointer.scroll(dx: step.x, dy: step.y)
        coast = coast * exp(-min(dt, 0.05) / 0.35)
        if coast.length < 40 { coast = .zero }
    }

    private func apply(_ actions: [GestureAction], dt: Double, at t: Double) {
        posted.removeAll { t - $0.t > 0.5 }
        for action in actions {
            switch action {
            case .move(let d):
                let p = acceleration.points(for: d, dt: dt)
                pointer.move(dx: p.x, dy: p.y)
                posted.append((t, p))
            case .undo(_, let seconds):
                // The engine's moves up to the last frame: same frame times as `posted`.
                let back = posted.filter { t - $0.t <= seconds + 0.001 }.reduce(Vec2.zero) { $0 + $1.p }
                posted.removeAll { t - $0.t <= seconds + 0.001 }
                if back != .zero { pointer.move(dx: -back.x, dy: -back.y) }
            case .press:
                pointer.press()
            case .release:
                pointer.release()
            case .click:
                pointer.click()
            case .rightClick:
                pointer.rightClick()
            case .dismissMenu:
                pointer.key(53)  // Escape
            case .scroll(let d):
                let p = acceleration.scrollPoints(for: d, dt: dt)
                let s = naturalScrolling ? 1.0 : -1.0
                pointer.scroll(dx: p.x * s, dy: p.y * s)
                recentScroll.append((t, Vec2(p.x * s, p.y * s)))
            case .swipe(let direction):
                // Like a trackpad: fling left, the desktop on the right comes in.
                if !swipesToApp { pointer.spaces(direction == .left ? 124 : 123) }
            case .talkStart, .talkEnd, .pause:
                break  // the app starts and stops dictation, and shows the pause
            }
        }
    }
}

/// Writes the raw camera frames to video.mov and the prompt labels to labels.json.
/// GlideReplay reads both and runs the whole pipeline again.
final class SessionRecorder {
    private let folder: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var start: CMTime?
    private var segments: [[String: Any]] = []
    private var events: [[String: Any]] = []
    private var lastTime = 0.0
    var label: String? {
        didSet {
            guard label != oldValue else { return }
            // Close the open segment only. A closed one keeps its end, so gaps stay out of steps.
            if oldValue != nil, !segments.isEmpty { segments[segments.count - 1]["end"] = lastTime }
            if let label { segments.append(["label": label, "start": lastTime, "end": lastTime]) }
        }
    }

    init?(folder: URL) {
        self.folder = folder
        guard let w = try? AVAssetWriter(outputURL: folder.appendingPathComponent("video.mov"), fileType: .mov) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 640,
            AVVideoHeightKey: 480,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000],
        ]
        let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { return nil }
        w.add(i)
        writer = w
        input = i
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: i, sourcePixelBufferAttributes: nil)
    }

    func append(_ pixels: CVPixelBuffer, at time: CMTime) {
        if start == nil {
            start = time
            writer.startWriting()
            writer.startSession(atSourceTime: time)
        }
        lastTime = (time - (start ?? time)).seconds
        if input.isReadyForMoreMediaData { adaptor.append(pixels, withPresentationTime: time) }
    }

    func log(_ event: [String: Any]) {
        var e = event
        e["t"] = lastTime
        events.append(e)
    }

    func finish(_ done: @escaping () -> Void) {
        label = nil
        let json = try? JSONSerialization.data(withJSONObject: ["segments": segments], options: [.prettyPrinted, .sortedKeys])
        try? json?.write(to: folder.appendingPathComponent("labels.json"))
        if !events.isEmpty {
            let ev = try? JSONSerialization.data(withJSONObject: ["events": events], options: [.prettyPrinted, .sortedKeys])
            try? ev?.write(to: folder.appendingPathComponent("events.json"))
        }
        guard start != nil else { done(); return }
        input.markAsFinished()
        writer.finishWriting(completionHandler: done)
    }
}
