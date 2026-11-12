import AppKit
import GlideCore

/// A click-through layer over the screen with the pointer. All feedback sits at the pointer, where the eyes are.
/// - A ring closes as the fingers close, so a click never comes as a surprise.
/// - A ripple on each click, two on a right-click, a solid dot while dragging.
/// - Near the edge of the camera view, a crescent lights up on that side of the ring: the hand is drifting out.
/// - When the hand is lost, a dashed ring stays at the pointer and fades: the pointer is parked.
/// - While the hand grabs, two short bars show the scroll; a fling shows an arrow.
final class ScreenOverlay: NSPanel {
    private let root = CALayer()
    private let ring = CAShapeLayer()
    private let crescent = CAShapeLayer()
    private let parked = CAShapeLayer()
    private var wasSeen = false

    init() {
        super.init(contentRect: NSScreen.main?.frame ?? .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .screenSaver
        ignoresMouseEvents = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        contentView = view

        for l in [ring, crescent, parked] {
            l.fillColor = nil
            l.strokeColor = NSColor.white.cgColor
            l.shadowColor = NSColor.black.cgColor
            l.shadowOpacity = 0.35
            l.shadowRadius = 2
            l.shadowOffset = .zero
            l.opacity = 0
            root.addSublayer(l)
        }
        ring.lineWidth = 2
        crescent.lineWidth = 3.5
        crescent.lineCap = .round
        parked.lineWidth = 1.5
        parked.lineDashPattern = [3, 4]
    }

    override var canBecomeKey: Bool { false }

    // MARK: - Update

    func update(_ s: TrackingSnapshot) {
        followPointerScreen()
        let c = cursorPoint()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)

        let r: CGFloat
        var alpha: Float
        switch s.mode {
        case .drag:
            r = 5; alpha = 1
            ring.fillColor = NSColor.white.cgColor
        case .pinch:
            // A held pinch grows and fills toward a right-click, which fires when it is full.
            // A middle-finger pinch shows the full ring at once: it right-clicks on release.
            let hold = s.middlePinch ? 1 : CGFloat(min(1, s.pinchHeld / GestureConfig().longPress))
            r = 7 + 9 * hold; alpha = 1
            ring.fillColor = NSColor.white.withAlphaComponent(0.2 + 0.45 * hold * hold).cgColor
        case .grab:
            r = 12; alpha = 0.9
            ring.fillColor = NSColor.white.withAlphaComponent(0.12).cgColor
        case .talk:
            r = 0; alpha = 0
        default:
            let p = CGFloat(s.pinchProgress)
            r = 22 - 15 * p; alpha = Float(pow(p, 1.4))
            ring.fillColor = nil
        }
        if !s.enabled { alpha = 0 }
        // Palm held up: a ring grows and fills toward pausing or resuming.
        var r2 = r
        if s.wakeProgress > 0 {
            r2 = 10 + 14 * CGFloat(s.wakeProgress)
            alpha = 1
            ring.fillColor = NSColor.white.withAlphaComponent(0.1 + 0.4 * CGFloat(s.wakeProgress)).cgColor
        }
        ring.path = circle(c, r2)
        ring.opacity = alpha

        // The hand drifts toward an edge of the camera view: light that side of a ring around the pointer.
        if let palm = s.palm, s.enabled {
            let x = 1 - palm.x  // mirrored, so the screen side matches the hand side
            // Recorded: the hand left the view with the palm 0.05 to 0.15 from the top or bottom, and Vision
            // dropped it from about 0.2. Top and bottom warn from 0.32; the sides, which it rarely leaves, from 0.22.
            let push = CGVector(dx: edge(x, 1, from: 0.22, full: 0.08) - edge(x, 0, from: 0.22, full: 0.08),
                                dy: edge(palm.y, 1, from: 0.32, full: 0.14) - edge(palm.y, 0, from: 0.32, full: 0.14))
            let strength = min(1, hypot(push.dx, push.dy))
            if strength > 0.01 {
                let angle = atan2(push.dy, push.dx)
                let arc = CGMutablePath()
                arc.addArc(center: c, radius: 26, startAngle: angle - 0.6, endAngle: angle + 0.6, clockwise: false)
                crescent.path = arc
            }
            crescent.opacity = Float(strength)
            parked.opacity = 0
            wasSeen = true
        } else {
            crescent.opacity = 0
        }
        CATransaction.commit()

        if s.palm == nil && wasSeen && s.enabled {
            wasSeen = false
            showParked(at: c)
        }
    }

    /// Feedback for an action at the pointer.
    func show(_ action: GestureAction) {
        let c = cursorPoint()
        switch action {
        case .click:
            ripple(at: c)
        case .rightClick:
            ripple(at: c)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.ripple(at: c) }
        case .release:
            ripple(at: c, size: 0.7)
        case .swipe(let d):
            arrow(at: c, left: d == .left)
        default:
            break
        }
    }

    // MARK: - Pieces

    /// 0 in the middle of the camera view, 1 at the edge `toward` (0 or 1).
    private func edge(_ v: CGFloat, _ toward: CGFloat, from: CGFloat, full: CGFloat) -> CGFloat {
        let d = abs(v - toward)
        let t = min(1, max(0, (from - d) / (from - full)))
        return t * t * (3 - 2 * t)
    }

    private func showParked(at c: CGPoint) {
        parked.removeAllAnimations()
        parked.path = circle(c, 14)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.9, 0.9, 0]
        fade.keyTimes = [0, 0.1, 0.6, 1]
        fade.duration = 1.6
        parked.add(fade, forKey: "parked")
    }

    private func arrow(at c: CGPoint, left: Bool) {
        let l = CAShapeLayer()
        let p = CGMutablePath()
        let d: CGFloat = left ? -1 : 1
        p.move(to: CGPoint(x: c.x - 14 * d, y: c.y))
        p.addLine(to: CGPoint(x: c.x + 14 * d, y: c.y))
        p.move(to: CGPoint(x: c.x + 6 * d, y: c.y + 8))
        p.addLine(to: CGPoint(x: c.x + 14 * d, y: c.y))
        p.addLine(to: CGPoint(x: c.x + 6 * d, y: c.y - 8))
        l.path = p
        l.strokeColor = NSColor.white.cgColor
        l.fillColor = nil
        l.lineWidth = 3
        l.lineCap = .round
        l.lineJoin = .round
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.35
        l.shadowRadius = 2
        l.shadowOffset = .zero
        root.addSublayer(l)

        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = 0
        slide.toValue = 40 * d
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [slide, fade]
        g.duration = 0.5
        g.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        g.isRemovedOnCompletion = false
        g.fillMode = .forwards
        l.add(g, forKey: "arrow")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { l.removeFromSuperlayer() }
    }

    private func ripple(at p: CGPoint, size: CGFloat = 1) {
        let r: CGFloat = 8 * size
        let l = CAShapeLayer()
        l.frame = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        l.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: r * 2, height: r * 2), transform: nil)
        l.fillColor = nil
        l.strokeColor = NSColor.white.cgColor
        l.lineWidth = 2
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.3
        l.shadowRadius = 2
        l.shadowOffset = .zero
        root.addSublayer(l)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.5
        grow.toValue = 3.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 0.45
        g.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
        g.isRemovedOnCompletion = false
        g.fillMode = .forwards
        l.add(g, forKey: "ripple")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { l.removeFromSuperlayer() }
    }

    private func circle(_ c: CGPoint, _ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), transform: nil)
    }

    // MARK: - Geometry

    /// Pointer position in this window, origin at the bottom left.
    private func cursorPoint() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x - frame.minX, y: m.y - frame.minY)
    }

    private func followPointerScreen() {
        let m = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) else { return }
        if frame != screen.frame || root.frame.size != screen.frame.size {
            setFrame(screen.frame, display: false)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.frame = CGRect(origin: .zero, size: screen.frame.size)
            for l in [ring, crescent, parked] { l.frame = root.bounds }
            CATransaction.commit()
        }
    }
}
