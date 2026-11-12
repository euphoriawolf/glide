import AppKit
import AVFoundation
import Combine
import GlideCore
import SwiftUI

/// A small desktop to try every gesture on real controls. While it records, each object logs what
/// happened to it, so a recording carries the intent: a click on the background is a false click,
/// a drop outside Archive is a failed drag. GlideReplay scores the tasks from the labels.
final class PlaygroundModel: ObservableObject {
    @Published var task: Int?            // index into PlaygroundScript.tasks; tasks.count = free play
    @Published var recording = false
    @Published var saved: URL?
    @Published var desktop = 0
    /// A short push toward a desktop that is not there, so a swipe the wrong way still shows it was seen.
    @Published var bounce: CGFloat = 0
    @Published var lit: Set<String> = []
    @Published var archived: [String] = []
    @Published var folders: [String: CGPoint] = PlaygroundModel.home
    @Published var text = ""
    @Published var renamed = false
    @Published var done = false

    static let home: [String: CGPoint] = [
        "Photos": CGPoint(x: 90, y: 90), "Projects": CGPoint(x: 220, y: 90), "Music": CGPoint(x: 90, y: 230),
    ]

    var start: () -> URL? = { nil }
    var stop: (@escaping () -> Void) -> Void = { $0() }
    var setLabel: (String?) -> Void = { _ in }
    var log: ([String: Any]) -> Void = { _ in }

    /// Screen corner the pointer must reach in a reach task: tl, tr, br, bl.
    var corner: String? { current?.kind == .reach ? current?.id : nil }
    private var lostAt: Date?

    /// Called with every tracking frame while the window is open. Finishes the out-of-view tasks.
    func handSeen(_ seen: Bool) {
        guard let t = current, t.kind == .leave, !done else { return }
        if !seen {
            if lostAt == nil { lostAt = Date() }
        } else if let lost = lostAt {
            lostAt = nil
            let gone = Date().timeIntervalSince(lost)
            if gone >= 0.4 { event(t.label, ["outOfView": (gone * 100).rounded() / 100]) }
        }
    }

    /// The pointer, checked 20 times a second during a reach task.
    func pointer(_ p: NSPoint, on screen: NSRect) {
        guard let c = corner, !done else { return }
        let target: NSPoint
        switch c {
        case "tl": target = NSPoint(x: screen.minX, y: screen.maxY)
        case "tr": target = NSPoint(x: screen.maxX, y: screen.maxY)
        case "br": target = NSPoint(x: screen.maxX, y: screen.minY)
        default: target = NSPoint(x: screen.minX, y: screen.minY)
        }
        if hypot(p.x - target.x, p.y - target.y) < 40 {
            event("reach:\(c)", ["x": Int(p.x - screen.minX), "y": Int(screen.maxY - p.y)])
        }
    }

    var current: PlaygroundTask? {
        guard let task, task < PlaygroundScript.tasks.count else { return nil }
        return PlaygroundScript.tasks[task]
    }

    func begin() {
        reset()
        saved = nil
        guard let folder = start() else { return }
        lastFolder = folder
        recording = true
        task = 0
        setLabel(PlaygroundScript.tasks[0].label)
    }

    func end() {
        setLabel(nil)
        recording = false
        task = nil
        stop { [weak self] in self?.saved = self?.lastFolder }
    }
    var lastFolder: URL?

    func skip() {
        guard let t = current else { return }
        event("skip", ["task": t.label])
        advance()
    }

    /// A semantic event from an object. Finishes the current task when it matches.
    func event(_ name: String, _ extra: [String: Any] = [:]) {
        var e = extra
        e["source"] = "playground"
        e["event"] = name
        log(e)
        if let t = current, t.label == name, !done {
            done = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.advance() }
        }
    }

    func flash(_ id: String) {
        lit.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.lit.remove(id) }
    }

    func swipe(_ d: SwipeDirection) {
        // Like a trackpad: swipe left, the desktop on the right comes in.
        let next = d == .left ? min(1, desktop + 1) : max(0, desktop - 1)
        guard next != desktop else {
            event("swipe:edge", ["direction": d == .left ? "left" : "right"])
            withAnimation(.spring(response: 0.18, dampingFraction: 0.9)) { bounce = d == .left ? -40 : 40 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { self.bounce = 0 }
            }
            return
        }
        withAnimation(.smooth(duration: 0.45)) { desktop = next }
        event(next == 1 ? "swipe:next" : "swipe:back")
    }

    private func advance() {
        done = false
        guard let task else { return }
        let next = task + 1
        self.task = next
        if next < PlaygroundScript.tasks.count {
            setLabel(PlaygroundScript.tasks[next].label)
        } else {
            setLabel("free")
        }
    }

    private func reset() {
        archived = []
        folders = Self.home
        text = ""
        renamed = false
        desktop = 0
        done = false
    }
}

final class PlaygroundWindow: NSWindow {
    let model = PlaygroundModel()
    let tracking: TrackingView
    private var monitor: Any?
    private var corners: [String: CornerGlow] = [:]
    private var watch: AnyCancellable?
    private var timer: Timer?

    init(session: AVCaptureSession) {
        tracking = TrackingView(session: session)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "Playground"
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        minSize = NSSize(width: 980, height: 640)
        contentView = NSHostingView(rootView: PlaygroundView(model: model, tracking: tracking))
        center()
        setFrameAutosaveName("GlidePlayground")

        // Reach tasks: a glow in the target screen corner, and a pointer check.
        watch = model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.showCorner(self?.model.corner) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, self.model.corner != nil, let screen = self.screen ?? NSScreen.main else { return }
            self.model.pointer(NSEvent.mouseLocation, on: screen.frame)
        }

        // Raw button events in this window, beside the objects' own events.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown]) { [weak self] e in
            guard let self, e.window === self, self.model.recording else { return e }
            let p = e.locationInWindow
            let kind = e.type == .leftMouseDown ? "down" : e.type == .leftMouseUp ? "up" : "rightDown"
            self.model.log(["source": "window", "event": kind, "x": Int(p.x), "y": Int(self.frame.height - p.y),
                            "clicks": e.clickCount])
            return e
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        timer?.invalidate()
    }

    override func close() {
        showCorner(nil)
        super.close()
    }

    private func showCorner(_ id: String?) {
        for (key, glow) in corners where key != id { glow.orderOut(nil) }
        guard let id, let screen = screen ?? NSScreen.main else { return }
        let glow = corners[id] ?? CornerGlow(corner: id)
        corners[id] = glow
        glow.place(on: screen.frame)
        glow.orderFrontRegardless()
    }
}

/// A soft glow in one corner of the screen: the target of a reach task. Clicks pass through it.
private final class CornerGlow: NSPanel {
    let corner: String
    private let size: CGFloat = 140

    init(corner: String) {
        self.corner = corner
        super.init(contentRect: NSRect(x: 0, y: 0, width: 140, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let anchor: UnitPoint = switch corner {
        case "tl": .topLeading
        case "tr": .topTrailing
        case "br": .bottomTrailing
        default: .bottomLeading
        }
        contentView = NSHostingView(rootView: CornerGlowView(anchor: anchor))
    }

    func place(on screen: NSRect) {
        let x = corner.hasSuffix("l") ? screen.minX : screen.maxX - size
        let y = corner.hasPrefix("t") ? screen.maxY - size : screen.minY
        setFrame(NSRect(x: x, y: y, width: size, height: size), display: true)
    }
}

private struct CornerGlowView: View {
    let anchor: UnitPoint
    @State private var pulse = false

    var body: some View {
        RadialGradient(colors: [Color.accentColor.opacity(pulse ? 0.75 : 0.5), Color.accentColor.opacity(0)],
                       center: anchor, startRadius: 0, endRadius: 140)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}

// MARK: - Views

private struct PlaygroundView: View {
    @ObservedObject var model: PlaygroundModel
    let tracking: TrackingView

    var body: some View {
        VStack(spacing: 0) {
            TaskBar(model: model, tracking: tracking)
                .padding(.horizontal, 24)
                .padding(.top, 34)
                .padding(.bottom, 16)
            ZStack {
                if model.desktop == 0 {
                    DeskOne(model: model)
                        .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
                } else {
                    DeskTwo(model: model)
                        .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .trailing)))
                }
            }
            .offset(x: model.bounce)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding([.horizontal, .bottom], 24)
        }
        .background(.background)
    }
}

private struct TaskBar: View {
    @ObservedObject var model: PlaygroundModel
    let tracking: TrackingView

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 24, weight: .semibold))
                    .contentTransition(.opacity)
                    .animation(.smooth, value: title)
                if model.task != nil {
                    HStack(spacing: 5) {
                        ForEach(0..<PlaygroundScript.tasks.count, id: \.self) { i in
                            Capsule()
                                .fill(i < (model.task ?? 0) || (i == model.task && model.done) ? Color.green : Color.primary.opacity(i == model.task ? 0.5 : 0.12))
                                .frame(width: i == model.task ? 22 : 8, height: 8)
                        }
                    }
                    .animation(.smooth, value: model.task)
                }
            }
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<2, id: \.self) { i in
                    Circle().fill(Color.primary.opacity(model.desktop == i ? 0.7 : 0.15)).frame(width: 7, height: 7)
                }
            }
            controls
            LiveTracking(tracking: tracking)
                .frame(width: 128, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var title: String {
        if let t = model.current { return model.done ? "Done" : t.prompt }
        if model.task != nil { return "Free play" }
        if model.saved != nil { return "Saved" }
        return "Playground"
    }

    @ViewBuilder private var controls: some View {
        if model.recording {
            if model.current != nil {
                Button("Skip") { model.skip() }
                    .controlSize(.large)
            }
            Button {
                model.end()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .controlSize(.large)
            .tint(.red)
            .buttonStyle(.borderedProminent)
        } else {
            if let url = model.saved {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .controlSize(.large)
            }
            Button {
                model.begin()
            } label: {
                Label("Record", systemImage: "record.circle")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Desktop 1: field, targets, files and folders, a long list.
private struct DeskOne: View {
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 22) {
                Field(model: model)
                Targets(model: model)
                Spacer(minLength: 0)
            }
            .frame(width: 320)
            Desk(model: model)
            Rows(model: model)
                .frame(width: 220)
        }
        .padding(18)
        .background(Missable(model: model, desktop: 1))
        .background(Color.primary.opacity(0.035))
    }
}

/// Desktop 2: nothing to hit. Swipe here and back.
private struct DeskTwo: View {
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.blue.opacity(0.18), Color.purple.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Text("2")
                .font(.system(size: 220, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.08))
        }
        .background(Missable(model: model, desktop: 2))
    }
}

/// The background: a click here hit nothing.
private struct Missable: View {
    @ObservedObject var model: PlaygroundModel
    let desktop: Int

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .global) { p in
                model.event("miss", ["desktop": desktop, "x": Int(p.x), "y": Int(p.y)])
            }
    }
}

private struct Field: View {
    @ObservedObject var model: PlaygroundModel
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $model.text)
            .font(.system(size: 15))
            .scrollContentBackground(.hidden)
            .padding(10)
            .frame(height: 150)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(focused ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: focused ? 2 : 1))
            .focused($focused)
            .onChange(of: focused) { _, on in model.event(on ? "focus:field" : "blur:field") }
            .onChange(of: model.text) { old, new in
                guard !new.isEmpty, new.count > old.count else { return }
                model.event("type:field", ["added": new.count - old.count])
            }
    }
}

private struct Targets: View {
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 26) {
                circle("large", 110)
                circle("medium", 60)
                circle("small", 26)
            }
            Button("Save") {
                model.flash("button")
                model.event("click:button")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func circle(_ id: String, _ size: CGFloat) -> some View {
        let on = model.lit.contains(id)
        return Circle()
            .fill(on ? Color.accentColor : Color.accentColor.opacity(0.22))
            .overlay(Circle().stroke(Color.accentColor.opacity(0.6), lineWidth: 1.5))
            .frame(width: size, height: size)
            .scaleEffect(on ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
            .contentShape(Circle())
            .onTapGesture {
                model.flash(id)
                model.event("click:\(id)")
            }
    }
}

/// Folders to drag into Archive, and a file with a right-click menu.
private struct Desk: View {
    @ObservedObject var model: PlaygroundModel
    @State private var dragging: String?
    @State private var offset = CGSize.zero

    var body: some View {
        GeometryReader { geo in
            let archive = CGRect(x: geo.size.width - 170, y: geo.size.height - 170, width: 150, height: 150)
            let over = dragging.map { isOver(archive, $0) } ?? false
            ZStack(alignment: .topLeading) {
                // Archive
                VStack(spacing: 8) {
                    Image(systemName: model.archived.isEmpty ? "archivebox" : "archivebox.fill")
                        .font(.system(size: 54, weight: .light))
                    Text("Archive").font(.system(size: 13, weight: .medium))
                    if !model.archived.isEmpty {
                        Text(model.archived.joined(separator: ", "))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: archive.width, height: archive.height)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(over ? 0.14 : 0.05)))
                .scaleEffect(over ? 1.06 : 1)
                .animation(.spring(response: 0.3), value: over)
                .position(x: archive.midX, y: archive.midY)

                // The file with a menu
                FileIcon(name: model.renamed ? "Notes 2" : "Notes", symbol: "doc.text")
                    .contextMenu {
                        Button("Rename") {
                            model.renamed = true
                            model.event("rightClick:notes")
                        }
                        Button("Duplicate") { model.event("menu:duplicate") }
                        Button("Move to Trash") { model.event("menu:trash") }
                    }
                    .position(x: 350, y: 90)

                ForEach(Array(model.folders.keys.sorted()), id: \.self) { name in
                    if !model.archived.contains(name), let home = model.folders[name] {
                        let lifted = dragging == name
                        FileIcon(name: name, symbol: "folder.fill")
                            .scaleEffect(lifted ? 1.08 : 1)
                            .shadow(color: .black.opacity(lifted ? 0.25 : 0), radius: 10, y: 6)
                            .position(x: home.x + (lifted ? offset.width : 0), y: home.y + (lifted ? offset.height : 0))
                            .zIndex(lifted ? 1 : 0)
                            .gesture(
                                DragGesture(minimumDistance: 4, coordinateSpace: .named("desk"))
                                    .onChanged { v in
                                        if dragging != name {
                                            dragging = name
                                            model.event("dragStart:\(name.lowercased())")
                                        }
                                        offset = v.translation
                                    }
                                    .onEnded { v in
                                        // A drop outside the desk lands on its nearest edge, so a folder is never lost.
                                        let end = CGPoint(x: min(max(home.x + v.translation.width, 50), geo.size.width - 50),
                                                          y: min(max(home.y + v.translation.height, 50), geo.size.height - 50))
                                        if archive.contains(end) {
                                            withAnimation(.smooth) { model.archived.append(name) }
                                            model.event("drag:\(name.lowercased())", ["dropped": "archive"])
                                        } else {
                                            model.folders[name] = end
                                            model.event("dragEnd:\(name.lowercased())", ["dropped": "desk"])
                                        }
                                        dragging = nil
                                        offset = .zero
                                    }
                            )
                    }
                }
            }
            .coordinateSpace(name: "desk")
        }
    }

    private func isOver(_ archive: CGRect, _ name: String) -> Bool {
        guard let home = model.folders[name] else { return false }
        return archive.contains(CGPoint(x: home.x + offset.width, y: home.y + offset.height))
    }
}

private struct FileIcon: View {
    let name: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 46))
                .foregroundStyle(symbol == "folder.fill" ? Color.accentColor : Color.primary.opacity(0.7))
            Text(name).font(.system(size: 13))
        }
        .frame(width: 96, height: 96)
        .contentShape(Rectangle())
    }
}

private struct Rows: View {
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(1...60, id: \.self) { i in
                    HStack {
                        Text("Row \(i)").font(.system(size: 14, weight: i == 40 ? .semibold : .regular))
                        Spacer()
                        if i == 40 { Image(systemName: "flag.fill").foregroundStyle(Color.accentColor) }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(i % 2 == 0 ? Color.primary.opacity(0.03) : .clear)
                    .id(i)
                }
            }
            .scrollTargetLayout()
        }
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.8) { ids in
            if ids.contains(40) { model.event("scroll:list") }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LiveTracking: NSViewRepresentable {
    let tracking: TrackingView
    func makeNSView(context: Context) -> TrackingView { tracking }
    func updateNSView(_ nsView: TrackingView, context: Context) {}
}
