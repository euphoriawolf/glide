import Foundation

/// The hand shapes Glide reads.
/// open: move the pointer, pinch to click. fist: grab the page to scroll, fling to switch desktop.
/// two (index and middle finger up): hold to talk.
public enum HandPose: Equatable {
    case open, two, fist
}

public struct PoseClassifier {
    /// A finger is extended when its tip is this much farther from the wrist than its middle joint.
    public var extendedRatio = 1.18
    /// A finger is curled when its tip is closer to the wrist than this.
    public var curledRatio = 1.0
    /// A finger is folded into the palm, as in a fist, below this.
    /// A pinching index finger is bent (about 1.0 to 1.15), not folded, so a pinch never reads as a fist.
    /// Recorded: an intended grab reads 0.6 to 0.7; false grabs from a relaxed hand read 0.77 and up.
    public var foldedRatio = 0.85
    /// The three folded fingers must also average below this.
    public var foldedMean = 0.8
    /// Curled fingertips are often hidden, so this is lower than the pointer threshold.
    public var minConfidence = 0.15

    public init() {}

    /// Tip-to-wrist over middle-joint-to-wrist for index, middle, ring, little. Nil when a joint is not seen.
    public func ratios(_ f: HandFrame) -> [Double?] {
        guard let wrist = f.point(.wrist, minConfidence: minConfidence) else { return [nil, nil, nil, nil] }
        let fingers: [(HandFrame.Joint, HandFrame.Joint)] = [
            (.indexPIP, .indexTip), (.middlePIP, .middleTip), (.ringPIP, .ringTip), (.littlePIP, .littleTip),
        ]
        return fingers.map { pip, tip in
            guard let p = f.point(pip, minConfidence: minConfidence),
                  let t = f.point(tip, minConfidence: minConfidence) else { return nil }
            return (t - wrist).length / max((p - wrist).length, 1e-6)
        }
    }

    public func classify(_ f: HandFrame) -> HandPose {
        classify(ratios: ratios(f))
    }

    public func classify(ratios r: [Double?]) -> HandPose {
        func below(_ i: Int, _ limit: Double) -> Bool { r[i].map { $0 < limit } ?? false }
        func above(_ i: Int, _ limit: Double) -> Bool { r[i].map { $0 > limit } ?? false }

        // Grab: index, middle and ring folded into the palm. The little finger can do anything.
        if below(0, foldedRatio) && below(1, foldedRatio) && below(2, foldedRatio),
           let a = r[0], let b = r[1], let c = r[2], (a + b + c) / 3 < foldedMean {
            return .fist
        }
        // Talk: index and middle straight up, ring and little curled.
        if above(0, extendedRatio) && above(1, extendedRatio) && below(2, curledRatio) && below(3, curledRatio) {
            return .two
        }
        return .open
    }
}
