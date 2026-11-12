import AppKit
import AVFoundation
import GlideVision
import GlideCore
import Vision

/// Live view of the hand: a frosted camera image with light on the hand.
/// A soft glow follows the hand, a colored orb sits on each fingertip, and a pinch sends out a ripple.
final class TrackingView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private let shade = CALayer()
    private let overlay = CALayer()
    private let body = CAShapeLayer()       // soft light along the fingers
    private let palm = CAGradientLayer()
    private let trails = CAShapeLayer()
    private var orbs: [Orb] = []
    private let ghost = CAShapeLayer()      // ignored hands
    private let hold = CAShapeLayer()       // ring while a pinch or scroll is held
    private let idle = CAShapeLayer()       // breathing ring when no hand is seen

    private var history: [[CGPoint]] = Array(repeating: [], count: 5)
    private var lastMode: GestureMode = .idle
    private var aspect: CGFloat = 4.0 / 3.0

    var cornerRadius: CGFloat = 0 { didSet { needsLayout = true } }

    private static let tips: [VNHumanHandPoseObservation.JointName] = [.thumbTip, .indexTip, .middleTip, .ringTip, .littleTip]
    private static let fingers: [[VNHumanHandPoseObservation.JointName]] = [
        [.wrist, .thumbCMC, .thumbMP, .thumbIP, .thumbTip],
        [.indexMCP, .indexPIP, .indexDIP, .indexTip],
        [.middleMCP, .middlePIP, .middleDIP, .middleTip],
        [.ringMCP, .ringPIP, .ringDIP, .ringTip],
        [.littleMCP, .littlePIP, .littleDIP, .littleTip],
        [.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP, .wrist],
    ]
    /// One light for the whole hand.
    static let light = NSColor.white
    private let approach = CAShapeLayer()   // thread of light between thumb and index as they close

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true

        preview.videoGravity = .resizeAspectFill
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 10]),
           let tone = CIFilter(name: "CIColorControls", parameters: [kCIInputSaturationKey: 0.4, kCIInputBrightnessKey: -0.05]) {
            preview.filters = [blur, tone]
        }
        shade.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor

        body.fillColor = nil
        body.strokeColor = NSColor.white.withAlphaComponent(0.10).cgColor
        body.lineCap = .round
        body.lineJoin = .round
        body.shadowColor = NSColor.white.cgColor
        body.shadowOpacity = 0.5
        body.shadowRadius = 10
        body.shadowOffset = .zero

        palm.type = .radial
        palm.colors = [NSColor.white.withAlphaComponent(0.20).cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        palm.startPoint = CGPoint(x: 0.5, y: 0.5)
        palm.endPoint = CGPoint(x: 1, y: 1)
        palm.opacity = 0

        trails.fillColor = nil
        trails.lineCap = .round
        trails.lineJoin = .round

        ghost.fillColor = NSColor.white.withAlphaComponent(0.22).cgColor

        for l in [hold, idle] {
            l.fillColor = nil
            l.lineWidth = 2
        }
        hold.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        hold.shadowColor = NSColor.white.cgColor
        hold.shadowRadius = 8
        hold.shadowOpacity = 0.8
        hold.shadowOffset = .zero
        hold.opacity = 0

        idle.strokeColor = NSColor.white.cgColor
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.08
        breathe.toValue = 0.35
        breathe.duration = 1.6
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        idle.add(breathe, forKey: "breathe")

        approach.fillColor = nil
        approach.strokeColor = NSColor.white.cgColor
        approach.lineWidth = 2
        approach.lineCap = .round
        approach.shadowColor = NSColor.white.cgColor
        approach.shadowRadius = 6
        approach.shadowOpacity = 1
        approach.shadowOffset = .zero
        approach.opacity = 0

        orbs = (0..<5).map { _ in Orb(color: Self.light) }
        for l in [palm, body, trails, ghost, approach] { overlay.addSublayer(l) }
        orbs.forEach { overlay.addSublayer($0) }
        overlay.addSublayer(hold)
        overlay.addSublayer(idle)
        for l in [preview, shade, overlay] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = cornerRadius
        // Oversize the blurred camera so its soft edge stays outside the view.
        preview.frame = bounds.insetBy(dx: -20, dy: -20)
        shade.frame = bounds
        overlay.frame = bounds
        for l in [body, trails, ghost, hold, idle, approach] { l.frame = bounds }
        let r = min(bounds.width, bounds.height) * 0.16
        idle.path = CGPath(ellipseIn: CGRect(x: bounds.midX - r, y: bounds.midY - r, width: r * 2, height: r * 2), transform: nil)
        CATransaction.commit()
    }

    // MARK: - Update

    func update(_ s: TrackingSnapshot) {
        aspect = CGFloat(s.aspect)
        let seen = !s.joints.isEmpty
        let scale = handScale(s.joints)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.07)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))

        idle.isHidden = seen
        palm.opacity = seen ? 1 : 0
        if let w = s.joints[.wrist], let m = s.joints[.middleMCP] {
            let c = map(CGPoint(x: (w.x + m.x) / 2, y: (w.y + m.y) / 2))
            let d = scale * 3.2
            palm.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            palm.position = c
        }

        body.lineWidth = max(6, scale * 0.38)
        body.path = path(s.joints, chains: Self.fingers)

        // Fingertip orbs and their trails.
        let trailPath = CGMutablePath()
        for (i, joint) in Self.tips.enumerated() {
            let orb = orbs[i]
            guard let p = s.joints[joint] else {
                orb.opacity = 0
                history[i].removeAll()
                continue
            }
            let q = map(p)
            orb.opacity = 1
            orb.position = q
            orb.setSize(max(14, scale * 0.42), core: max(4, scale * 0.07))
            history[i].insert(q, at: 0)
            if history[i].count > 6 { history[i].removeLast() }
            if history[i].count > 1 { trailPath.addLines(between: history[i]) }
        }
        trails.path = trailPath
        trails.lineWidth = max(3, scale * 0.06)
        trails.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor

        // Thumb and index closing: a thread of light between them brightens until they touch.
        if let a = s.joints[.thumbTip], let b = s.joints[.indexTip], s.mode == .hover, s.pinchProgress > 0.02 {
            let p = CGMutablePath()
            p.move(to: map(a))
            p.addLine(to: map(b))
            approach.path = p
            approach.opacity = Float(pow(s.pinchProgress, 1.3))
            approach.lineWidth = 1 + 2 * CGFloat(s.pinchProgress)
        } else {
            approach.opacity = 0
        }

        // Pinch or drag: the two touching fingertips flare, a ripple goes out once, a ring stays while held.
        let pinched = s.mode == .pinch || s.mode == .drag
        orbs.forEach { $0.setLit(false) }
        if pinched, let a = s.joints[.thumbTip], let b = s.joints[.indexTip] {
            let mid = map(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2))
            orbs[0].setLit(true)
            orbs[1].setLit(true)
            let r = max(10, scale * 0.28) * (s.mode == .drag ? 0.7 : 1)
            hold.path = CGPath(ellipseIn: CGRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2), transform: nil)
            hold.opacity = 1
            if lastMode != .pinch && lastMode != .drag { ripple(at: mid, radius: r, color: .white) }
        } else {
            hold.opacity = 0
        }
        // Grab: all fingertips flare. Talk: the two raised fingertips flare.
        if s.mode == .grab { orbs.forEach { $0.setLit(true) } }
        if s.mode == .talk { orbs[1].setLit(true); orbs[2].setLit(true) }
        lastMode = s.mode

        // Ignored hands: a faint glow on each fingertip, nothing more.
        let ghostPath = CGMutablePath()
        for other in s.others {
            for joint in Self.tips {
                guard let p = other[joint] else { continue }
                let q = map(p)
                ghostPath.addEllipse(in: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6))
            }
        }
        ghost.path = ghostPath

        CATransaction.commit()
    }

    private func ripple(at p: CGPoint, radius r: CGFloat, color: NSColor) {
        let ring = CAShapeLayer()
        ring.frame = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: r * 2, height: r * 2), transform: nil)
        ring.fillColor = nil
        ring.strokeColor = color.cgColor
        ring.lineWidth = 2
        ring.shadowColor = color.cgColor
        ring.shadowRadius = 6
        ring.shadowOpacity = 1
        ring.shadowOffset = .zero
        overlay.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.6
        grow.toValue = 3.2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.55
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        ring.add(group, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { ring.removeFromSuperlayer() }
    }

    // MARK: - Geometry

    /// Vision point (0...1, origin bottom left, not mirrored) to a point in this view.
    /// macOS layers have their origin at the bottom left too, so y needs no flip.
    private func map(_ p: CGPoint) -> CGPoint {
        let f = preview.frame
        var w = f.width, h = f.width / aspect
        if h < f.height { h = f.height; w = h * aspect }
        let mirrored = preview.connection?.isVideoMirrored ?? true
        let x = mirrored ? 1 - p.x : p.x
        return CGPoint(x: f.midX - w / 2 + x * w, y: f.midY - h / 2 + p.y * h)
    }

    private func handScale(_ j: Joints) -> CGFloat {
        guard let w = j[.wrist], let m = j[.middleMCP] else { return 40 }
        let a = map(w), b = map(m)
        return hypot(a.x - b.x, a.y - b.y)
    }

    private func path(_ j: Joints, chains: [[VNHumanHandPoseObservation.JointName]]) -> CGPath {
        let p = CGMutablePath()
        for chain in chains {
            let pts = chain.compactMap { j[$0].map(map) }
            if pts.count > 1 { p.addLines(between: pts) }
        }
        return p
    }
}

/// A fingertip: a bright core inside a colored glow.
private final class Orb: CALayer {
    private let glow = CAGradientLayer()
    private let core = CALayer()
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init()
        glow.type = .radial
        glow.colors = [color.withAlphaComponent(0.75).cgColor, color.withAlphaComponent(0.25).cgColor, color.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.35, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        core.backgroundColor = NSColor.white.cgColor
        core.shadowColor = color.cgColor
        core.shadowRadius = 5
        core.shadowOpacity = 1
        core.shadowOffset = .zero
        addSublayer(glow)
        addSublayer(core)
        opacity = 0
    }

    override init(layer: Any) {
        color = (layer as? Orb)?.color ?? .white
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setSize(_ glowSize: CGFloat, core c: CGFloat) {
        bounds = CGRect(x: 0, y: 0, width: glowSize, height: glowSize)
        glow.frame = bounds
        core.frame = CGRect(x: (glowSize - c) / 2, y: (glowSize - c) / 2, width: c, height: c)
        core.cornerRadius = c / 2
    }

    func setLit(_ lit: Bool) {
        glow.transform = lit ? CATransform3DMakeScale(1.7, 1.7, 1) : CATransform3DIdentity
        core.shadowRadius = lit ? 10 : 5
    }
}

/// Small floating preview. Stays above all windows and on every Space. Drag it anywhere.
final class PreviewPanel: NSPanel {
    let tracking: TrackingView

    init(session: AVCaptureSession) {
        tracking = TrackingView(session: session)
        tracking.cornerRadius = 18
        super.init(contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = tracking
        tracking.layer?.borderWidth = 1
        tracking.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        if !setFrameUsingName("GlidePreview"), let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 20, y: screen.minY + 20))
        }
        setFrameAutosaveName("GlidePreview")
    }

    override var canBecomeKey: Bool { false }
}
