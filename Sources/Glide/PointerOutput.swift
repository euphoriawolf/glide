import AppKit
import CoreGraphics

/// Posts pointer, button, scroll and key events. Coordinates: global, origin at top left.
final class PointerOutput {
    private let source = CGEventSource(stateID: .hidSystemState)
    private(set) var buttonDown = false
    private var scrollRemainder = CGPoint.zero
    private var lastClickTime = 0.0
    private var lastClickPoint = CGPoint.zero
    private var clickCount = 1

    var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    func move(dx: Double, dy: Double) {
        let from = location
        let p = clampToDisplays(CGPoint(x: from.x + dx, y: from.y + dy))
        // Real mouse events carry the distance moved. Some apps and window drags read it.
        post(buttonDown ? .leftMouseDragged : .mouseMoved, at: p, button: .left, delta: CGPoint(x: p.x - from.x, y: p.y - from.y))
    }

    func click() {
        let p = location
        countClick(at: p)
        post(.leftMouseDown, at: p, button: .left)
        post(.leftMouseUp, at: p, button: .left)
    }

    func press() {
        let p = location
        clickCount = 1
        buttonDown = true
        post(.leftMouseDown, at: p, button: .left)
    }

    func release() {
        guard buttonDown else { return }
        buttonDown = false
        post(.leftMouseUp, at: location, button: .left)
    }

    func rightClick() {
        let p = location
        clickCount = 1
        post(.rightMouseDown, at: p, button: .right)
        post(.rightMouseUp, at: p, button: .right)
    }

    /// Positive y shows content above (the page moves down).
    func scroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let x = Int32(scrollRemainder.x.rounded(.towardZero))
        let y = Int32(scrollRemainder.y.rounded(.towardZero))
        guard x != 0 || y != 0 else { return }
        scrollRemainder.x -= Double(x)
        scrollRemainder.y -= Double(y)
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    func key(_ code: CGKeyCode) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    /// The macOS shortcuts behind three-finger swipes: Control + arrow.
    /// Mission Control and Spaces shortcuts carry the fn flag in System Settings.
    func spaces(_ arrow: CGKeyCode) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: arrow, keyDown: down) else { continue }
            e.flags = [.maskControl, .maskSecondaryFn]
            e.post(tap: .cghidEventTap)
        }
    }

    private func countClick(at p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let near = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 8
        clickCount = (now - lastClickTime < NSEvent.doubleClickInterval && near) ? clickCount + 1 : 1
        lastClickTime = now
        lastClickPoint = p
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, delta: CGPoint = .zero) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if delta != .zero {
            e.setDoubleValueField(.mouseEventDeltaX, value: delta.x)
            e.setDoubleValueField(.mouseEventDeltaY, value: delta.y)
        }
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        e.post(tap: .cghidEventTap)
    }

    private func clampToDisplays(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let bounds = ids.map { CGDisplayBounds($0) }
        if bounds.contains(where: { $0.contains(p) }) { return p }
        let current = location
        let home = bounds.first(where: { $0.contains(current) }) ?? bounds.first ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: min(max(p.x, home.minX), home.maxX - 1),
                       y: min(max(p.y, home.minY), home.maxY - 1))
    }
}
