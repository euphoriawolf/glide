import Foundation

/// Turns hand travel (camera units) into screen points, like macOS pointer acceleration.
/// Very slow hand: nothing (tremor). Slow hand: low gain, for precision. Fast hand: high gain, to cross the screen.
public struct PointerAcceleration {
    /// Tracking speed, as in the Mouse settings. 1 is the default.
    public var speed = 1.0
    public var minGain = 900.0
    /// Recorded: reaching the top screen corners pushed the hand out of the camera view at 5200.
    public var maxGain = 7000.0
    /// Below this hand speed (camera units per second) the pointer does not move.
    public var tremorSpeed = 0.006
    /// Hand speed where the gain starts to rise.
    public var slowSpeed = 0.04
    /// Hand speed where the gain is at its maximum.
    public var fastSpeed = 0.7
    public var scrollSpeed = 1.0
    public var scrollGain = 2600.0

    public init() {}

    public func points(for delta: Vec2, dt: Double) -> Vec2 {
        let v = delta.length / max(dt, 1.0 / 120)
        let still = Self.smoothstep(tremorSpeed, tremorSpeed * 3, v)
        let s = Self.smoothstep(slowSpeed, fastSpeed, v)
        return delta * ((minGain + (maxGain - minGain) * s) * speed * still)
    }

    /// Fast strokes scroll farther, up to 2.5 times. Recorded: scrolling 40 rows took 8 grabs at a flat gain.
    public func scrollPoints(for delta: Vec2, dt: Double = 1.0 / 30) -> Vec2 {
        let v = delta.length / max(dt, 1.0 / 120)
        let boost = 1 + 1.5 * Self.smoothstep(0.1, 0.8, v)
        return delta * (scrollGain * scrollSpeed * boost)
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
