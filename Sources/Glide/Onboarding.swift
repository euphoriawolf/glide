import AppKit
import AVFoundation
import GlideCore
import SwiftUI
import Vision

// MARK: - Model

final class OnboardingModel: ObservableObject {
    enum Step: Int, CaseIterable {
        case camera, access, mic, raise, click, rightClick, drag, scroll, desktops, voice, done
        static let practice: [Step] = [.raise, .click, .rightClick, .drag, .scroll, .desktops, .voice]
        var isPractice: Bool { Self.practice.contains(self) }
        var usesCamera: Bool { isPractice && self != .voice }
    }

    @Published var step: Step = .camera
    /// 0...1 for the practice step. Fills the tick ring.
    @Published var progress = 0.0
    @Published var passed = false
    /// No progress for a while. Shows a hint, as Face ID does.
    @Published var stalled = false
    @Published var cameraDenied = false
    @Published var micDenied = false
    /// macOS can keep reporting "not trusted" to a running app. A restart reads the new state.
    @Published var showRestart = false
    @Published var showPreview: Bool
    @Published var voiceText = ""
    var keyName = "fn"

    var requestCamera: () -> Void = {}
    var requestAccess: () -> Void = {}
    var requestMic: () -> Void = {}
    var setPrimary: (VNChirality) -> Void = { _ in }
    var setPreview: (Bool) -> Void = { _ in }
    var finish: () -> Void = {}
    /// Called on every step change. The app turns Glide on for the last screen, so a pinch can press Done.
    var onStep: (Step) -> Void = { _ in }
    private var doneWork: DispatchWorkItem?

    private var frames = 0
    private var travel = 0.0
    private var lastPalm: CGPoint?
    private var counts = (clicks: 0, right: 0, swipes: 0)
    private var base = (clicks: 0, right: 0, swipes: 0)
    private var trustTimer: Timer?
    private var stallWork: DispatchWorkItem?

    init(showPreview: Bool) {
        self.showPreview = showPreview
    }

    /// Picks the first step that is not yet done.
    func begin() {
        let camera = AVCaptureDevice.authorizationStatus(for: .video)
        if camera != .authorized {
            cameraDenied = camera == .denied
            go(.camera)
        } else if !AXIsProcessTrusted() {
            go(.access)
        } else if !Dictation.micAllowed {
            go(.mic)
        } else {
            go(.raise)
        }
    }

    func go(_ s: Step) {
        frames = 0
        travel = 0
        lastPalm = nil
        base = counts
        trustTimer?.invalidate()
        stallWork?.cancel()
        withAnimation(.smooth(duration: 0.5)) {
            passed = false
            stalled = false
            showRestart = false
            progress = 0
            voiceText = ""
            step = s
        }
        onStep(s)
        doneWork?.cancel()
        if s == .done {
            // Glide works from here. If the screen is left alone, it closes by itself.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.step == .done else { return }
                self.finish()
            }
            doneWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
        }
        if s == .access {
            trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                if AXIsProcessTrusted() { self?.advance() }
            }
        }
        if s.isPractice {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.step == s, self.progress < 0.05 else { return }
                withAnimation(.smooth) { self.stalled = true }
            }
            stallWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
        }
    }

    /// The step before this one, skipping permissions that are already granted.
    var previous: Step? {
        var r = step.rawValue - 1
        while r >= 0, let s = Step(rawValue: r) {
            if !isGranted(s) { return s }
            r -= 1
        }
        return nil
    }

    func back() {
        if let p = previous { go(p) }
    }

    /// Page dots: any lesson, or a permission that is still missing.
    func canJump(to s: Step) -> Bool { s != step && !isGranted(s) }

    func isGranted(_ s: Step) -> Bool {
        switch s {
        case .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .access: AXIsProcessTrusted()
        case .mic: Dictation.micAllowed
        default: false
        }
    }

    func advance() {
        guard var next = Step(rawValue: step.rawValue + 1) else { return }
        if next == .access && AXIsProcessTrusted() { next = .mic }
        if next == .mic && Dictation.micAllowed { next = .raise }
        go(next)
    }

    func cameraGranted(_ granted: Bool) {
        if granted { advance() } else { cameraDenied = true }
    }

    func micGranted(_ granted: Bool) {
        if granted { advance() } else { withAnimation(.smooth) { micDenied = true } }
    }

    func allowAccess() {
        requestAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, self.step == .access, !AXIsProcessTrusted() else { return }
            withAnimation(.smooth) { self.showRestart = true }
        }
    }

    func restart() {
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: Practice

    /// Practice steps fill the ring as the live gesture is seen.
    func handle(_ s: TrackingSnapshot) {
        counts = (s.clicks, s.rightClicks, s.swipes)
        guard step.usesCamera, !passed else { return }
        var p = progress
        var done = false
        switch step {
        case .raise:
            frames = s.mode == .idle ? 0 : frames + 1
            p = Double(frames) / 15
        case .click:
            let n = counts.clicks - base.clicks
            if n == 1 { setPrimary(s.chirality) }
            p = Double(n) / 3
        case .rightClick:
            done = counts.right > base.right
            p = done ? 1 : (s.mode == .pinch ? min(0.95, s.pinchHeld / GestureConfig().longPress) : 0)
        case .drag:
            if s.mode == .drag, let palm = s.palm, let last = lastPalm {
                travel += hypot(palm.x - last.x, palm.y - last.y)
            }
            lastPalm = s.palm
            p = travel / 0.3
        case .scroll:
            frames = s.mode == .grab ? frames + 1 : max(0, frames - 1)
            p = Double(frames) / 25
        case .desktops:
            done = counts.swipes > base.swipes
            p = done ? 1 : min(0.95, s.swipeProgress)
        default:
            break
        }
        p = min(1, p)
        if p != progress { progress = p }
        if p > 0.05 && stalled { withAnimation(.smooth) { stalled = false } }
        if p >= 1 || done { pass() }
    }

    func voiceListening(_ level: Float) {
        guard step == .voice, !passed else { return }
        progress = min(0.9, max(progress, 0.15 + Double(level)))
        if stalled { withAnimation(.smooth) { stalled = false } }
    }

    func voiceHeard(_ text: String) {
        guard step == .voice, !passed else { return }
        withAnimation(.smooth) { voiceText = text }
        progress = 1
        pass()
    }

    private func pass() {
        guard !passed else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.65)) { passed = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + (step == .voice ? 2.0 : 1.0)) { [weak self] in self?.advance() }
    }
}

// MARK: - Window

final class OnboardingWindow: NSWindow {
    let model: OnboardingModel
    let tracking: TrackingView

    init(session: AVCaptureSession, model: OnboardingModel) {
        self.model = model
        tracking = TrackingView(session: session)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 580),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: OnboardingView(model: model, tracking: tracking))
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        center()
    }

    func update(_ s: TrackingSnapshot) {
        if isVisible && model.step.usesCamera { tracking.update(s) }
        model.handle(s)
    }
}

// MARK: - Views

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let tracking: TrackingView

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 44)
            hero.frame(width: 260, height: 260)
            Spacer(minLength: 24)
            words
                .id(model.step)
                .transition(.blurReplace)
                .frame(maxWidth: 340, minHeight: 80, alignment: .top)
            Spacer(minLength: 12)
            actions.frame(height: model.step == .done ? 96 : 72, alignment: .top)
            PageDots(model: model)
                .padding(.top, 14)
                .padding(.bottom, 24)
        }
        .frame(width: 440, height: 580)
        .overlay(alignment: .topLeading) {
            if model.previous != nil {
                Button { model.back() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.1), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.leftArrow, modifiers: [])
                .help("Back")
                .padding(.top, 8)
                .padding(.leading, 44)
                .transition(.opacity)
            }
        }
    }

    // MARK: Hero

    @ViewBuilder private var hero: some View {
        if model.step.isPractice {
            ZStack {
                TickRing(progress: model.progress, done: model.passed)
                Group {
                    if model.step.usesCamera {
                        LiveView(tracking: tracking)
                    } else {
                        // Voice: the demo itself, large.
                        ZStack {
                            Color.black.opacity(0.35)
                            GestureDemo(kind: .voice).frame(width: 150, height: 150)
                        }
                    }
                }
                .clipShape(Circle())
                .padding(28)
                .overlay {
                    if model.passed {
                        ZStack {
                            Circle().fill(.black.opacity(0.35)).padding(28)
                            Image(systemName: "checkmark")
                                .font(.system(size: 60, weight: .semibold))
                                .foregroundStyle(.white)
                                .symbolEffect(.bounce, value: model.passed)
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                if model.step.usesCamera && !model.passed, let kind = demoKind {
                    GestureDemo(kind: kind)
                        .frame(width: 76, height: 76)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.15)))
                        .id(model.step)
                        .transition(.scale.combined(with: .opacity))
                        .offset(x: 96, y: 96)
                }
            }
            .transition(.blurReplace)
        } else {
            ZStack {
                Aura(done: model.step == .done)
                Circle()
                    .fill(.black.opacity(0.3))
                    .padding(50)
                Image(systemName: icon)
                    .font(.system(size: 64, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
                    .symbolEffect(.bounce, value: model.step)
                    .symbolEffect(.pulse, isActive: model.step == .access && model.showRestart)
                    .id(model.step)
                    .transition(.blurReplace)
            }
            .transition(.blurReplace)
        }
    }

    private var demoKind: GestureDemo.Kind? {
        switch model.step {
        case .raise: .raise
        case .click: .click
        case .rightClick: .rightClick
        case .drag: .drag
        case .scroll: .scroll
        case .desktops: .desktops
        default: nil
        }
    }

    // MARK: Copy

    private var words: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .transition(.blurReplace)
            }
        }
    }

    private var icon: String {
        switch model.step {
        case .camera: "camera.fill"
        case .access: "cursorarrow.motionlines"
        case .mic: "mic.fill"
        default: "checkmark"
        }
    }

    private var title: String {
        switch model.step {
        case .camera: "Glide sees your hand through the camera"
        case .access: "Let Glide move the pointer"
        case .mic: "Talk instead of typing"
        case .raise: "Raise one hand"
        case .click: "Pinch to click"
        case .rightClick: "Pinch and hold to right-click"
        case .drag: "Pinch and move to drag"
        case .scroll: "Close your hand to grab and scroll"
        case .desktops: "Swipe to switch desktops"
        case .voice: "Two fingers up and talk"
        case .done: "You're set"
        }
    }

    private var detail: String? {
        if model.step == .voice && !model.voiceText.isEmpty { return "“\(model.voiceText)”" }
        if model.stalled {
            switch model.step {
            case .raise: return "Palm toward the screen, about an arm's length away, with light on your hand."
            case .click: return "Touch the fingertips together, then open."
            case .rightClick: return "Keep the hand still until the ring fills."
            case .drag: return "Keep the fingertips together while the hand moves."
            case .scroll: return "Close all fingers, then move the hand up or down."
            case .desktops: return "Spread all fingers wide, then sweep the hand quickly left or right."
            case .voice: return "Index and middle finger up, the other fingers folded. If fn opens the emoji panel, set Keyboard › Press fn key to › Do Nothing."
            default: break
            }
        }
        switch model.step {
        case .camera: return model.cameraDenied ? "Turn on Glide in Camera settings." : nil
        case .access:
            // A switched-on entry can belong to an older signature of Glide. Only a fresh entry fixes that.
            return model.showRestart
                ? "Still asking? Select Glide in the list, click −, then click Allow again."
                : "Turn on Glide in the list."
        case .mic: return model.micDenied ? "Turn on Glide in Microphone settings." : "Speech stays on this Mac."
        case .click: return "Three times. This hand moves the pointer."
        case .scroll: return "The page moves with your hand."
        case .desktops: return "Spread your hand, then swipe left or right."
        case .voice: return "In a text field. Lower the hand to type it. Or hold \(model.keyName)."
        default: return nil
        }
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch model.step {
        case .camera:
            Button(model.cameraDenied ? "Open Settings" : "Allow Camera") {
                if model.cameraDenied {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
                } else {
                    model.requestCamera()
                }
            }
            .buttonStyle(Primary())
        case .access:
            VStack(spacing: 12) {
                Button("Allow") { model.allowAccess() }
                    .buttonStyle(Primary())
                if model.showRestart {
                    Button("Already on? Restart Glide") { model.restart() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .transition(.blurReplace)
                }
            }
        case .mic:
            VStack(spacing: 12) {
                Button(model.micDenied ? "Open Settings" : "Allow Microphone") {
                    if model.micDenied {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    } else {
                        model.requestMic()
                    }
                }
                .buttonStyle(Primary())
                Button("Not now") { model.go(.raise) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        case .done:
            VStack(spacing: 16) {
                HStack(spacing: 20) {
                    HStack(spacing: 4) {
                        ForEach(["⌃", "⌥", "Space"], id: \.self) { k in
                            Text(k)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        }
                        Text("on or off").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Toggle("Preview", isOn: Binding(
                        get: { model.showPreview },
                        set: { model.showPreview = $0; model.setPreview($0) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(.system(size: 12))
                }
                Button("Done") { model.finish() }
                    .buttonStyle(Primary())
                    .keyboardShortcut(.defaultAction)
            }
        default:
            Button("Skip") { model.advance() }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pieces

private struct LiveView: NSViewRepresentable {
    let tracking: TrackingView
    func makeNSView(context: Context) -> TrackingView { tracking }
    func updateNSView(_ nsView: TrackingView, context: Context) {}
}

/// Face ID style: ticks around the circle grow and light up as the gesture is seen.
private struct TickRing: View {
    var progress: Double
    var done: Bool
    private let count = 80

    var body: some View {
        GeometryReader { g in
            let r = min(g.size.width, g.size.height) / 2
            ZStack {
                ForEach(0..<count, id: \.self) { i in
                    let on = done || Double(i) < progress * Double(count)
                    Capsule()
                        .fill(done ? Color.green : on ? Color.white : Color.white.opacity(0.16))
                        .frame(width: 2.5, height: on ? 15 : 9)
                        .offset(y: -r + 9)
                        .rotationEffect(.degrees(Double(i) / Double(count) * 360))
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: on)
                        .animation(.easeOut(duration: 0.3).delay(Double(i) * 0.004), value: done)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// A slow-turning field of white light behind an icon. Green when done.
private struct Aura: View {
    var done: Bool
    @State private var turn = false

    var body: some View {
        let colors: [Color] = done
            ? [.green, .mint, .green.opacity(0.6), .mint]
            : [.white, .white.opacity(0.35), .white.opacity(0.8), .white.opacity(0.25)]
        AngularGradient(colors: colors + [colors[0]], center: .center)
            .clipShape(Circle())
            .padding(32)
            .blur(radius: 36)
            .opacity(0.6)
            .rotationEffect(.degrees(turn ? 360 : 0))
            .animation(.linear(duration: 14).repeatForever(autoreverses: false), value: turn)
            .onAppear { turn = true }
    }
}

/// Page dots. The current step is a wider capsule. Click a dot to go to that lesson.
private struct PageDots: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        let current = model.step.rawValue
        HStack(spacing: 2) {
            ForEach(OnboardingModel.Step.allCases, id: \.self) { s in
                let i = s.rawValue
                Button { model.go(s) } label: {
                    Capsule()
                        .fill(i == current ? Color.primary : Color.primary.opacity(i < current ? 0.45 : 0.18))
                        .frame(width: i == current ? 18 : 6, height: 6)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canJump(to: s))
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: current)
    }
}

private struct Primary: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 210, height: 40)
            .background(Color.accentColor, in: Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: - Gesture demos

/// Vector animations of each gesture. Glowing white dots are fingertips, the same light as the hand view.
struct GestureDemo: View {
    enum Kind { case raise, click, rightClick, drag, scroll, desktops, voice }
    let kind: Kind

    private var period: Double {
        switch kind {
        case .click: 1.6
        case .rightClick, .drag: 2.4
        case .scroll: 1.8
        default: 2.2
        }
    }

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
            Canvas { ctx, size in
                let s = min(size.width, size.height) / 2
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                func at(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + x * s, y: c.y + y * s) }
                draw(&ctx, t: t, s: s, at: at)
            }
        }
    }

    // swiftlint:disable:next function_body_length
    private func draw(_ ctx: inout GraphicsContext, t: Double, s: CGFloat, at: (Double, Double) -> CGPoint) {
        // Thumb and index sit on a diagonal and close toward the middle.
        func pair(_ gap: Double, dx: Double = 0, alpha: Double = 1) {
            let d = gap / 2 * 0.707
            dot(&ctx, at(-d + dx, d), s * 0.11, alpha)
            dot(&ctx, at(d + dx, -d), s * 0.11, alpha)
        }

        switch kind {
        case .click:
            let gap = 0.75 * (1 - ease(t, 0, 0.3)) + 0.75 * ease(t, 0.55, 0.85)
            pair(gap)
            if t > 0.3 { ripple(&ctx, at(0, 0), s * CGFloat(0.15 + 0.75 * ease(t, 0.3, 0.75)), 1 - ease(t, 0.3, 0.75)) }

        case .rightClick:
            // Fingertips meet and hold while a ring fills, then two ripples.
            let gap = 0.75 * (1 - ease(t, 0, 0.2)) + 0.75 * ease(t, 0.78, 0.95)
            pair(gap)
            if t > 0.2 && t < 0.7 {
                let p = ease(t, 0.22, 0.62)
                var arc = Path()
                arc.addArc(center: at(0, 0), radius: s * 0.5, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * p), clockwise: false)
                ctx.stroke(arc, with: .color(.white.opacity(0.9)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            for start in [0.62, 0.7] where t > start {
                ripple(&ctx, at(0, 0), s * CGFloat(0.2 + 0.7 * ease(t, start, start + 0.25)), 1 - ease(t, start, start + 0.25))
            }

        case .drag:
            let gap = 0.6 * (1 - ease(t, 0, 0.18)) + 0.6 * ease(t, 0.72, 0.86)
            let x = -0.4 + 0.8 * ease(t, 0.22, 0.68)
            let alpha = ease(t, 0, 0.06) * (1 - ease(t, 0.9, 1))
            if t > 0.22 && t < 0.86 {
                var trail = Path()
                trail.move(to: at(-0.4, 0))
                trail.addLine(to: at(x, 0))
                ctx.stroke(trail, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
            pair(gap, dx: x, alpha: alpha)

        case .scroll:
            // Four fingertips close into a grab, the grab moves down and up, then opens.
            let close = ease(t, 0, 0.18) * (1 - ease(t, 0.85, 1))
            let y = 0.3 * sin(ease(t, 0.2, 0.82) * 2 * .pi)
            let spread: [(Double, Double)] = [(-0.36, -0.2), (-0.12, -0.36), (0.12, -0.36), (0.36, -0.2)]
            if close > 0.9 {
                for i in 1...4 {
                    let ty = 0.3 * sin(ease(t - Double(i) * 0.02, 0.2, 0.82) * 2 * .pi)
                    dot(&ctx, at(0, ty), s * 0.13, 0.12, glow: false)
                }
            }
            for (x0, y0) in spread {
                dot(&ctx, at(x0 * (1 - close) + x0 * 0.25 * close, y0 * (1 - close) + 0.0 * close + y * close), s * 0.09, 1)
            }

        case .desktops:
            // An open hand, fingers spread, swept sideways fast.
            let sweep = ease(t, 0.35, 0.5)
            let x = 0.3 - 0.8 * sweep
            let a = ease(t, 0, 0.12) * (1 - ease(t, 0.55, 0.75))
            let spread = ease(t, 0.05, 0.3)
            let tips: [(Double, Double)] = [(-0.3, 0.06), (-0.14, -0.22), (0, -0.28), (0.14, -0.22), (0.27, -0.08)]
            if t > 0.35 && t < 0.7 {
                for (tx, ty) in tips {
                    var streak = Path()
                    streak.move(to: at(0.3 + tx * (0.6 + 0.4 * spread), ty * (0.6 + 0.4 * spread)))
                    streak.addLine(to: at(x + tx * (0.6 + 0.4 * spread), ty * (0.6 + 0.4 * spread)))
                    ctx.stroke(streak, with: .color(.white.opacity(0.18 * a)), style: StrokeStyle(lineWidth: s * 0.08, lineCap: .round))
                }
            }
            for (tx, ty) in tips {
                dot(&ctx, at(x + tx * (0.6 + 0.4 * spread), ty * (0.6 + 0.4 * spread)), s * 0.07, a)
            }
            if t > 0.5 && t < 0.9 {
                let k = 1 - ease(t, 0.5, 0.9)
                var arrow = Path()
                arrow.move(to: at(-0.3, -0.16)); arrow.addLine(to: at(-0.48, 0)); arrow.addLine(to: at(-0.3, 0.16))
                ctx.stroke(arrow, with: .color(.white.opacity(k)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

        case .raise:
            let rise = ease(t, 0, 0.45)
            let a = rise * (1 - ease(t, 0.8, 1))
            let tips: [(Double, Double)] = [(-0.42, 0.12), (-0.2, -0.28), (0, -0.38), (0.2, -0.3), (0.38, -0.12)]
            for (i, tip) in tips.enumerated() {
                let delay = Double(i) * 0.04
                let r = ease(t, delay, 0.45 + delay)
                dot(&ctx, at(tip.0, tip.1 + 0.5 * (1 - r)), s * 0.09, a)
            }

        case .voice:
            // Two fingers up, a V, and the voice beside it.
            let rise = ease(t, 0, 0.2)
            for (x, y) in [(-0.52, -0.3), (-0.22, -0.3)] {
                var finger = Path()
                finger.move(to: at(-0.37, 0.3))
                finger.addLine(to: at(x, 0.3 - 0.6 * rise))
                ctx.stroke(finger, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
                dot(&ctx, at(x, 0.3 - 0.6 * rise + (y + 0.3) * 0), s * 0.09, rise)
            }
            for i in 0..<5 {
                let h = 0.12 + 0.34 * rise * (0.5 + 0.5 * sin(t * 2 * .pi * 2 + Double(i) * 1.1))
                let x = 0.1 + Double(i) * 0.12
                var bar = Path()
                bar.move(to: at(x, -h / 2))
                bar.addLine(to: at(x, h / 2))
                ctx.stroke(bar, with: .color(.white), style: StrokeStyle(lineWidth: s * 0.055, lineCap: .round))
            }
        }
    }

    private func dot(_ ctx: inout GraphicsContext, _ p: CGPoint, _ r: CGFloat, _ alpha: Double, glow: Bool = true) {
        guard alpha > 0.01 else { return }
        if glow {
            ctx.drawLayer { g in
                g.addFilter(.blur(radius: r * 1.1))
                g.fill(Path(ellipseIn: CGRect(x: p.x - r * 1.6, y: p.y - r * 1.6, width: r * 3.2, height: r * 3.2)),
                       with: .color(.white.opacity(0.45 * alpha)))
            }
        }
        ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)), with: .color(.white.opacity(alpha)))
    }

    private func ripple(_ ctx: inout GraphicsContext, _ p: CGPoint, _ r: CGFloat, _ alpha: Double) {
        guard alpha > 0.01 else { return }
        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                   with: .color(.white.opacity(alpha)), lineWidth: 2)
    }

    private func ease(_ t: Double, _ a: Double, _ b: Double) -> Double {
        let x = min(max((t - a) / (b - a), 0), 1)
        return x * x * (3 - 2 * x)
    }
}
