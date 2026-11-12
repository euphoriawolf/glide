import AppKit
import AVFoundation
import GlideCore
import SwiftUI

/// A guided recording: prompts from TestScript, camera video and labels saved for GlideReplay.
final class TestSessionModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case countdown(Int)
        case step(Int)
        case gap(next: Int)
        case saving
        case done(URL)
    }

    @Published var phase: Phase = .ready
    /// 0...1 of the current step or gap.
    @Published var progress = 0.0

    var start: () -> URL? = { nil }
    var setLabel: (String?) -> Void = { _ in }
    var stop: (@escaping () -> Void) -> Void = { $0() }
    private var task: Task<Void, Never>?

    var running: Bool {
        switch phase {
        case .ready, .done: false
        default: true
        }
    }

    func begin() {
        task = Task { @MainActor in
            for c in [3, 2, 1] {
                phase = .countdown(c)
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            guard let folder = start() else {
                phase = .ready
                return
            }
            let steps = TestScript.steps
            for (i, step) in steps.enumerated() {
                phase = .step(i)
                setLabel(step.label)
                await tick(step.seconds)
                setLabel(nil)
                if Task.isCancelled { return }
                if i < steps.count - 1 {
                    phase = .gap(next: i + 1)
                    await tick(TestScript.gap)
                }
            }
            phase = .saving
            stop { [weak self] in self?.phase = .done(folder) }
        }
    }

    func cancel() {
        task?.cancel()
        setLabel(nil)
        stop { [weak self] in self?.phase = .ready }
    }

    @MainActor private func tick(_ seconds: Double) async {
        let start = Date()
        progress = 0
        while !Task.isCancelled {
            let p = Date().timeIntervalSince(start) / seconds
            progress = min(1, p)
            if p >= 1 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

final class TestSessionWindow: NSWindow {
    let model = TestSessionModel()
    let tracking: TrackingView

    init(session: AVCaptureSession) {
        tracking = TrackingView(session: session)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                   styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        title = "Test Session"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        contentView = NSHostingView(rootView: TestSessionView(model: model, tracking: tracking))
        center()
    }
}

private struct TestSessionView: View {
    @ObservedObject var model: TestSessionModel
    let tracking: TrackingView

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle().stroke(.white.opacity(0.12), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: model.progress)
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.05), value: model.progress)
                LiveTracking(tracking: tracking)
                    .clipShape(Circle())
                    .padding(10)
                if case .countdown(let n) = model.phase {
                    Text("\(n)")
                        .font(.system(size: 72, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                }
            }
            .frame(width: 240, height: 240)

            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: 380, minHeight: 80, alignment: .top)
            .id(title)
            .transition(.blurReplace)
            .animation(.smooth, value: title)

            actions.frame(height: 44)
        }
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: 460, height: 560)
    }

    private var title: String {
        switch model.phase {
        case .ready: "Test Session"
        case .countdown: "Get ready"
        case .step(let i): TestScript.steps[i].prompt
        case .gap(let next): "Next: \(TestScript.steps[next].prompt)"
        case .saving: "Saving"
        case .done: "Saved"
        }
    }

    private var detail: String? {
        switch model.phase {
        case .ready: "About 90 seconds. Follow each prompt as you normally would. Nothing gets clicked."
        case .step(let i): "\(i + 1) of \(TestScript.steps.count)"
        case .done(let url): url.path
        default: nil
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .ready:
            Button("Start") { model.begin() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        case .done(let url):
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.large)
        case .saving:
            ProgressView()
        default:
            Button("Cancel") { model.cancel() }
                .controlSize(.large)
        }
    }
}

private struct LiveTracking: NSViewRepresentable {
    let tracking: TrackingView
    func makeNSView(context: Context) -> TrackingView { tracking }
    func updateNSView(_ nsView: TrackingView, context: Context) {}
}
