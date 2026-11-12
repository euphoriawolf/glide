import Foundation

/// One Euro filter (Casiez, Roussel, Vogel, CHI 2012).
/// Low speed: strong smoothing, less jitter. High speed: weak smoothing, less lag.
public struct OneEuroFilter {
    public var minCutoff: Double
    public var beta: Double
    public var dCutoff: Double

    private var value: Double?
    private var derivative: Double = 0
    private var lastTime: Double?

    public init(minCutoff: Double = 1.0, beta: Double = 0, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    public mutating func reset() {
        value = nil
        derivative = 0
        lastTime = nil
    }

    public mutating func filter(_ x: Double, at t: Double) -> Double {
        guard let previous = value, let lt = lastTime else {
            value = x
            lastTime = t
            return x
        }
        let dt = t - lt
        guard dt > 0 else { return previous }

        let rawDerivative = (x - previous) / dt
        derivative += Self.alpha(dCutoff, dt) * (rawDerivative - derivative)
        let cutoff = minCutoff + beta * abs(derivative)
        let result = previous + Self.alpha(cutoff, dt) * (x - previous)

        value = result
        lastTime = t
        return result
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

public struct OneEuroFilter2D {
    private var fx: OneEuroFilter
    private var fy: OneEuroFilter

    public init(minCutoff: Double, beta: Double, dCutoff: Double = 1.0) {
        fx = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
        fy = OneEuroFilter(minCutoff: minCutoff, beta: beta, dCutoff: dCutoff)
    }

    public mutating func reset() {
        fx.reset()
        fy.reset()
    }

    public mutating func filter(_ p: Vec2, at t: Double) -> Vec2 {
        Vec2(fx.filter(p.x, at: t), fy.filter(p.y, at: t))
    }
}
