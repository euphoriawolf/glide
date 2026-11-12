import CoreImage
import CoreVideo
import Foundation
import GlideCore
import Vision

public typealias Joints = [VNHumanHandPoseObservation.JointName: CGPoint]

/// What Vision saw in one camera frame.
public struct HandReading {
    /// The primary hand, ready for the gesture engine.
    public var frame: HandFrame?
    /// All joints of the primary hand, Vision coordinates.
    public var joints: Joints
    /// Joints of hands that Glide ignores.
    public var others: [Joints]
    public var chirality: VNChirality
    /// Palm of the primary hand, Vision coordinates (not mirrored).
    public var palm: CGPoint?
    public var handCount: Int
    public var boostEV: Double
    /// Camera image width divided by height.
    public var aspect: Double
}

/// Camera frame -> low-light boost -> Vision hand pose -> one primary hand.
/// The app and GlideReplay both use this, so a replay runs the same steps as the live app.
public final class HandReader {
    public var lowLightBoost = true
    /// Ignore hands of the other side. `.unknown`: either hand.
    public var primary = VNChirality.unknown

    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 2
        return r
    }()
    private var lastPalm: CGPoint?
    private var lastPalmTime = 0.0

    private let joints: [(VNHumanHandPoseObservation.JointName, HandFrame.Joint)] = [
        (.wrist, .wrist), (.middleMCP, .middleMCP),
        (.thumbTip, .thumbTip), (.indexTip, .indexTip), (.middleTip, .middleTip),
        (.ringTip, .ringTip), (.littleTip, .littleTip),
        (.indexPIP, .indexPIP), (.middlePIP, .middlePIP), (.ringPIP, .ringPIP), (.littlePIP, .littlePIP),
    ]

    public init() {}

    public func read(_ pixels: CVPixelBuffer, time t: Double) -> HandReading {
        var ev = 0.0
        let handler: VNImageRequestHandler
        if lowLightBoost, let luma = Self.meanLuma(pixels), luma < 0.3 {
            ev = min(2.5, max(0, log2(0.45 / max(luma, 0.02))))
            let boosted = CIImage(cvPixelBuffer: pixels)
                .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
                .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.75])
            handler = VNImageRequestHandler(ciImage: boosted, orientation: .up)
        } else {
            handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up)
        }
        try? handler.perform([request])

        let observations = request.results ?? []
        let chosen = choosePrimary(observations, t: t)
        let aspect = Double(CVPixelBufferGetWidth(pixels)) / Double(CVPixelBufferGetHeight(pixels))

        var reading = HandReading(frame: nil, joints: [:], others: [], chirality: chosen?.chirality ?? .unknown,
                                  palm: chosen == nil ? nil : lastPalm, handCount: observations.count,
                                  boostEV: ev, aspect: aspect)
        for o in observations {
            guard let recognized = try? o.recognizedPoints(.all) else { continue }
            var all: Joints = [:]
            for (name, p) in recognized where p.confidence > 0.3 { all[name] = p.location }
            guard o === chosen else { reading.others.append(all); continue }
            reading.joints = all
            var points: [HandFrame.Joint: Vec2] = [:]
            var confidence: [HandFrame.Joint: Double] = [:]
            for (name, joint) in joints {
                guard let p = recognized[name] else { continue }
                points[joint] = Vec2(p.location.x, p.location.y)
                confidence[joint] = Double(p.confidence)
            }
            reading.frame = HandFrame(points: points, confidence: confidence, aspect: aspect, time: t)
        }
        return reading
    }

    /// One hand at a time. Keep the hand already in use; never jump to the other hand.
    private func choosePrimary(_ observations: [VNHumanHandPoseObservation], t: Double) -> VNHumanHandPoseObservation? {
        var candidates = observations.compactMap { o in palm(o).map { (o, $0) } }
        if primary != .unknown {
            let opposite: VNChirality = primary == .left ? .right : .left
            candidates.removeAll { $0.0.chirality == opposite }
        }

        var pick: (VNHumanHandPoseObservation, CGPoint)?
        if let last = lastPalm, t - lastPalmTime < 0.5 {
            pick = candidates
                .map { ($0, hypot($0.1.x - last.x, $0.1.y - last.y)) }
                .filter { $0.1 < 0.25 }
                .min { $0.1 < $1.1 }?.0
        } else {
            pick = candidates.min { a, b in
                let ma = a.0.chirality == primary ? 0 : 1, mb = b.0.chirality == primary ? 0 : 1
                if ma != mb { return ma < mb }
                return handSize(a.0) > handSize(b.0)
            }
        }
        if let pick {
            lastPalm = pick.1
            lastPalmTime = t
        }
        return pick?.0
    }

    private func palm(_ o: VNHumanHandPoseObservation) -> CGPoint? {
        guard let w = try? o.recognizedPoint(.wrist), w.confidence > 0.3,
              let m = try? o.recognizedPoint(.middleMCP), m.confidence > 0.3 else { return nil }
        return CGPoint(x: (w.location.x + m.location.x) / 2, y: (w.location.y + m.location.y) / 2)
    }

    private func handSize(_ o: VNHumanHandPoseObservation) -> Double {
        guard let w = try? o.recognizedPoint(.wrist), let m = try? o.recognizedPoint(.middleMCP) else { return 0 }
        return hypot(w.location.x - m.location.x, w.location.y - m.location.y)
    }

    /// Mean brightness 0...1 from a sparse grid of BGRA pixels.
    static func meanLuma(_ buffer: CVPixelBuffer) -> Double? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 16) {
            for x in stride(from: 0, to: w, by: 16) {
                let i = y * row + x * 4
                sum += 0.114 * Double(bytes[i]) + 0.587 * Double(bytes[i + 1]) + 0.299 * Double(bytes[i + 2])
                n += 1
            }
        }
        return n > 0 ? sum / n / 255 : nil
    }
}
