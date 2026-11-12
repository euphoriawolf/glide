import Foundation

public struct Vec2: Equatable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)
    public var length: Double { (x * x + y * y).squareRoot() }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func += (a: inout Vec2, b: Vec2) { a = a + b }
}

/// One camera frame of hand joints, in Vision coordinates:
/// normalized 0...1, origin at the bottom left, not mirrored.
public struct HandFrame {
    public enum Joint: CaseIterable {
        case wrist, middleMCP
        case thumbTip, indexTip, middleTip, ringTip, littleTip
        case indexPIP, middlePIP, ringPIP, littlePIP
    }

    public var points: [Joint: Vec2]
    public var confidence: [Joint: Double]
    /// Image width divided by image height.
    public var aspect: Double
    public var time: Double

    public init(points: [Joint: Vec2], confidence: [Joint: Double] = [:], aspect: Double, time: Double) {
        self.points = points
        self.confidence = confidence
        self.aspect = aspect
        self.time = time
    }

    /// The joint in square units (x scaled by aspect), or nil when confidence is low.
    public func point(_ j: Joint, minConfidence: Double) -> Vec2? {
        guard let p = points[j] else { return nil }
        if let c = confidence[j], c < minConfidence { return nil }
        return Vec2(p.x * aspect, p.y)
    }
}
