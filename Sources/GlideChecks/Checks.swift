import Foundation
import GlideCore

/// Builds a frame. The palm is at (x, y), the hand size is 0.2.
/// `fingers`: which of index, middle, ring, little are extended (others are curled).
/// `pinch`: thumb-to-index distance as a ratio of hand size.
/// `tips` overrides `fingers`: tip height above the wrist per finger. The middle joint is at 0.27.
/// 0.36 = straight (ratio 1.33), 0.29 = bent (1.07), 0.18 = folded into the palm (0.67).
private func frame(x: Double, y: Double, pinch: Double = 1.0,
                   fingers: [Bool] = [true, true, true, true], tips: [Double]? = nil, middle: Double? = nil, t: Double) -> HandFrame {
    let wrist = Vec2(x, y - 0.1)
    var points: [HandFrame.Joint: Vec2] = [.wrist: wrist, .middleMCP: Vec2(x, y + 0.1)]
    let joints: [(HandFrame.Joint, HandFrame.Joint, Double)] = [
        (.indexPIP, .indexTip, -0.04), (.middlePIP, .middleTip, -0.013),
        (.ringPIP, .ringTip, 0.013), (.littlePIP, .littleTip, 0.04),
    ]
    for (i, (pip, tip, dx)) in joints.enumerated() {
        points[pip] = wrist + Vec2(dx, 0.27)
        points[tip] = wrist + Vec2(dx, tips?[i] ?? (fingers[i] ? 0.36 : 0.18))
    }
    // The thumb comes from outside the index, away from the middle finger, as on a real hand.
    // `middle`: the thumb sits that far below the middle fingertip instead.
    if let middle {
        points[.thumbTip] = points[.middleTip]! + Vec2(0, -middle * 0.2)
    } else {
        points[.thumbTip] = points[.indexTip]! + Vec2(-pinch * 0.2, 0)
    }
    return HandFrame(points: points, aspect: 1, time: t)
}

private func run(_ e: GestureEngine, _ frames: [(Double) -> HandFrame?], start: Double = 0) -> [GestureAction] {
    var all: [GestureAction] = []
    for (i, f) in frames.enumerated() {
        let t = start + Double(i) / 30
        all += e.update(f(t), now: t)
    }
    return all
}

private func moves(_ actions: [GestureAction]) -> Vec2 {
    actions.reduce(Vec2.zero) { sum, a in
        if case .move(let d) = a { return sum + d }
        if case .undo(let d, _) = a { return sum + d }
        return sum
    }
}

private func scrolls(_ actions: [GestureAction]) -> Vec2 {
    actions.reduce(Vec2.zero) { sum, a in
        if case .scroll(let d) = a { return sum + d }
        return sum
    }
}

private let still = { (r: Double) in { (t: Double) in frame(x: 0.5, y: 0.5, pinch: r, t: t) } }

func firstFrameDoesNotJump() {
    let e = GestureEngine()
    expect(e.update(frame(x: 0.5, y: 0.5, t: 0), now: 0).isEmpty)
    expect(e.mode == .hover)
}

func handMovingRightInImageMovesPointerLeft() {
    let e = GestureEngine()
    let total = moves(run(e, (0..<20).map { i in { t in frame(x: 0.3 + Double(i) * 0.01, y: 0.5, t: t) } }))
    expect(total.x < -0.05)
    expect(abs(total.y) < 0.001)
}

func handMovingUpInImageMovesPointerUp() {
    let e = GestureEngine()
    let total = moves(run(e, (0..<20).map { i in { t in frame(x: 0.5, y: 0.3 + Double(i) * 0.01, t: t) } }))
    expect(total.y < -0.05)
}

func quickPinchIsOneClick() {
    let e = GestureEngine()
    let out = run(e, [1.0, 1.0, 0.05, 0.05, 0.05, 0.05, 0.05, 0.05, 0.6, 0.6, 0.6].map(still))
    expect(out.filter { $0 == .click }.count == 1)
    expect(!out.contains(.press))
    expect(!out.contains(.rightClick))
    expect(e.clicks == 1)
}

func nearMissPinchDoesNotClick() {
    // Fingertips close (0.2 of hand size) but not touching.
    let e = GestureEngine()
    let out = run(e, [1.0, 0.2, 0.2, 0.2, 0.2, 1.0].map(still))
    expect(!out.contains(.click))
    expect(e.mode == .hover)
}

func pinchProgressRisesAsFingersClose() {
    let e = GestureEngine()
    _ = run(e, [1.0, 0.2].map(still))
    let mid = e.pinchProgress
    _ = run(e, [0.16].map(still), start: 1)
    expect(mid > 0 && mid < 1)
    expect(e.pinchProgress > mid)
}

func onePinchFrameIsIgnored() {
    let e = GestureEngine()
    let out = run(e, [1.0, 1.0, 0.05, 1.0, 1.0].map(still))
    expect(!out.contains(.click))
}

func ratioBetweenThresholdsKeepsThePinch() {
    let e = GestureEngine()
    _ = run(e, [1.0, 0.05, 0.05, 0.2, 0.2].map(still))
    expect(e.mode == .pinch)
}

/// A pinch held still past the long press: one right-click while held, no click on release, no drag.
func longStillPinchIsRightClick() {
    let e = GestureEngine()
    let out = run(e, Array(repeating: 0.05, count: 40).map(still) + [0.6, 0.6].map(still))
    expect(out.filter { $0 == .rightClick }.count == 1)
    expect(!out.contains(.click))
    expect(!out.contains(.press))
}

/// Held past the right-click, then moved: the menu closes and the drag starts, like lifting an icon on iPhone.
func holdThenMoveDrags() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in still(0.6) }
    frames += (0..<35).map { _ in still(0.05) }
    frames += (0..<15).map { i in { t in frame(x: 0.5 + Double(i) * 0.01, y: 0.5, pinch: 0.05, t: t) } }
    frames += (0..<3).map { _ in { t in frame(x: 0.64, y: 0.5, pinch: 0.6, t: t) } }
    let out = run(e, frames)
    expect(out.contains(.rightClick))
    expect(out.contains(.dismissMenu))
    expect(out.contains(.press) && out.contains(.release))
}

/// Moving on purpose before the long press is a drag, not a right-click.
func moveBeforeHoldDrags() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in still(0.6) }
    frames += (0..<8).map { _ in still(0.05) }
    frames += (0..<15).map { i in { t in frame(x: 0.5 + Double(i) * 0.01, y: 0.5, pinch: 0.05, t: t) } }
    frames += (0..<3).map { _ in { t in frame(x: 0.64, y: 0.5, pinch: 0.6, t: t) } }
    let out = run(e, frames)
    expect(out.contains(.press))
    expect(!out.contains(.rightClick))
}

/// Thumb on the middle fingertip, then open: a right-click.
func middlePinchRightClicks() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in still(0.6) }
    frames += (0..<8).map { _ in { t in frame(x: 0.5, y: 0.5, middle: 0.05, t: t) } }
    frames += (0..<4).map { _ in still(0.6) }
    let out = run(e, frames)
    expect(out.filter { $0 == .rightClick }.count == 1)
    expect(!out.contains(.click))
}

/// A middle-finger pinch that moves is still a right-click, never a drag.
func middlePinchDoesNotDrag() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in still(0.6) }
    frames += (0..<20).map { i in { t in frame(x: 0.5 + Double(i) * 0.01, y: 0.5, middle: 0.05, t: t) } }
    frames += (0..<4).map { _ in still(0.6) }
    let out = run(e, frames)
    expect(!out.contains(.press))
    expect(out.filter { $0 == .rightClick }.count == 1)
}

func pinchAndMoveDrags() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = []
    for i in 0..<20 {
        let x = i >= 4 ? 0.5 + Double(i - 4) * 0.01 : 0.5
        let r = i >= 1 ? 0.05 : 1.0
        frames.append { t in frame(x: x, y: 0.5, pinch: r, t: t) }
    }
    frames.append { t in frame(x: 0.66, y: 0.5, pinch: 0.6, t: t) }
    frames.append { t in frame(x: 0.66, y: 0.5, pinch: 0.6, t: t) }
    let out: [GestureAction] = run(e, frames)
    expect(out.contains(.press))
    expect(out.last == .release)
    expect(!out.contains(.click))
    let afterPress = Array(out.drop(while: { $0 != .press }))
    expect(moves(afterPress).x < -0.05)
}

func lostHandWhileDraggingReleases() {
    let e = GestureEngine()
    _ = run(e, (0..<12).map { i in { t in frame(x: 0.5 + Double(i) * 0.01, y: 0.5, pinch: 0.05, t: t) } })
    expect(e.mode == .drag)
    expect(e.update(nil, now: 0.45).isEmpty)  // short gap keeps the state
    expect(e.update(nil, now: 0.8) == [.release])
    expect(e.mode == .idle)
}

func reacquiredHandDoesNotJump() {
    let e = GestureEngine()
    _ = e.update(frame(x: 0.2, y: 0.5, t: 0), now: 0)
    _ = e.update(frame(x: 0.2, y: 0.5, t: 0.033), now: 0.033)
    _ = e.update(nil, now: 1)
    expect(moves(e.update(frame(x: 0.8, y: 0.5, t: 1.1), now: 1.1)) == .zero)
}

private let fist = [false, false, false, false]

private func isSwipe(_ a: GestureAction) -> Bool {
    if case .swipe = a { return true }
    return false
}

func grabScrolls() {
    let e = GestureEngine()
    let out = run(e, (0..<20).map { i in { t in
        frame(x: 0.5, y: i >= 5 ? 0.5 - Double(i - 5) * 0.01 : 0.5, fingers: fist, t: t)
    } })
    expect(e.mode == .grab)
    expect(scrolls(out).y > 0.05)  // hand down, page follows down
    expect(abs(moves(out).y) < 0.02)  // only the frames before the grab is confirmed
    expect(!out.contains(.click))
    expect(!out.contains(where: isSwipe))
}

func slowSidewaysGrabScrollsNotSwipes() {
    let e = GestureEngine()
    let out = run(e, (0..<30).map { i in { t in
        frame(x: i >= 5 ? 0.5 + Double(i - 5) * 0.01 : 0.5, y: 0.5, fingers: fist, t: t)
    } })
    expect(!out.contains(where: isSwipe))
    expect(scrolls(out).x < -0.1)
}

func spreadSwipeSwitchesDesktopOnce() {
    let e = GestureEngine()
    var p = Vec2(0.5, 0.5)
    let out = run(e, (0..<30).map { i in { t in
        if i >= 5 && i < 12 { p.x += 0.05 }  // 1.5 units/s, open spread hand
        return frame(x: p.x, y: p.y, t: t)
    } })
    expect(out.filter(isSwipe) == [.swipe(.left)])  // hand moved right in the image = left on screen
    expect(e.swipes == 1)
    let x = moves(out).x
    if abs(x) >= 0.02 { print("    pointer x after swipe: \(x)") }
    expect(abs(x) < 0.02)  // the pointer goes back to where the swipe began
}

/// Recorded: after a swipe the hand swings back at the same speed. That is not a second swipe.
func swingBackDoesNotSwipe() {
    let e = GestureEngine()
    var p = Vec2(0.5, 0.5)
    let out = run(e, (0..<40).map { i in { t in
        if i >= 5 && i < 12 { p.x += 0.05 }
        if i >= 14 && i < 21 { p.x -= 0.05 }
        return frame(x: p.x, y: p.y, t: t)
    } })
    expect(out.filter(isSwipe).count == 1)
}

/// Recorded: a relaxed hand (thumb near the index) moves fast across the screen. Only the pointer moves.
func relaxedFastMoveDoesNotSwipe() {
    let e = GestureEngine()
    var p = Vec2(0.5, 0.5)
    let out = run(e, (0..<30).map { i in { t in
        if i >= 5 && i < 12 { p.x += 0.05 }
        return frame(x: p.x, y: p.y, pinch: 0.32, t: t)
    } })
    expect(!out.contains(where: isSwipe))
    expect(moves(out).x < -0.2)
}

/// Recorded: fingertips touch for 0.3 s, then open slowly over 0.5 s. That is a click, not a right-click.
func slowOpeningClickIsNotRightClick() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in still(0.6) }
    frames += (0..<9).map { _ in still(0.08) }
    frames += (0..<15).map { i in still(0.15 + Double(i) * 0.01) }  // 0.15 to 0.29
    frames += (0..<5).map { _ in still(0.35) }
    let out = run(e, frames)
    expect(out.filter { $0 == .click }.count == 1)
    expect(!out.contains(.rightClick))
}

/// Recorded in use: the whole hand curls as the fingertips touch for 0.25 s, then opens wide. One click.
func wholeHandClickClicks() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<4).map { _ in still(0.6) }
    frames += (0..<8).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.05, tips: [0.25, 0.21, 0.18, 0.19], t: t) } }
    frames += (0..<5).map { _ in still(0.6) }
    let out = run(e, frames)
    expect(out.filter { $0 == .click }.count == 1)
}

/// Recorded in use: fingertips brushing for 2 frames while the hand moves. No click.
func brushDoesNotClick() {
    let e = GestureEngine()
    let out = run(e, [0.6, 0.6, 0.6, 0.08, 0.08, 0.08, 0.6, 0.6, 0.6].map(still))
    expect(!out.contains(.click))
}

/// Recorded in use: fingertips close to 0.16 to 0.21 without touching. No click.
func nearTouchDoesNotClick() {
    let e = GestureEngine()
    let out = run(e, ([0.6, 0.6] + Array(repeating: 0.17, count: 8) + [0.3, 0.6, 0.6]).map(still))
    expect(!out.contains(.click))
}

/// Recorded in the playground: a click held 2 s while the hand drifts 0.03 per second. Not a drag.
func slowDriftWhilePinchedDoesNotDrag() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in still(0.6) }
    frames += (0..<60).map { i in { t in frame(x: 0.5 + Double(i) * 0.001, y: 0.5, pinch: 0.05, t: t) } }
    frames += (0..<4).map { _ in { t in frame(x: 0.56, y: 0.5, pinch: 0.6, t: t) } }
    let out = run(e, frames)
    expect(!out.contains(.press))
}

/// A spread palm held still for 1 s pauses. While paused nothing moves. The same hold resumes.
func palmHoldPausesAndResumes() {
    let e = GestureEngine()
    var out = run(e, (0..<55).map { _ in still(1.0) })
    expect(out.contains(.pause(true)) && e.paused)
    // Paused: moving and pinching do nothing.
    var frames: [(Double) -> HandFrame?] = (0..<10).map { i in { t in frame(x: 0.5 + Double(i) * 0.02, y: 0.5, pinch: 0.3, t: t) } }
    frames += (0..<8).map { _ in still(0.05) } + (0..<4).map { _ in still(0.3) }
    out = run(e, frames, start: 2)
    expect(out.isEmpty)
    // Hold again: on.
    out = run(e, (0..<55).map { _ in still(1.0) }, start: 4)
    expect(out.contains(.pause(false)) && !e.paused)
}

/// A relaxed hand held still (thumb near the index) never pauses.
func relaxedStillHandDoesNotPause() {
    let e = GestureEngine()
    let out = run(e, (0..<90).map { _ in still(0.32) })
    expect(!out.contains(.pause(true)))
}

/// Recorded: people lower two fingers by folding them into a fist. That is not a grab.
func loweringTwoFingersDoesNotGrab() {
    let e = GestureEngine()
    let two = [true, true, false, false]
    var frames: [(Double) -> HandFrame?] = (0..<10).map { _ in { t in frame(x: 0.5, y: 0.5, fingers: two, t: t) } }
    frames += (0..<15).map { _ in { t in frame(x: 0.5, y: 0.5, fingers: fist, t: t) } }
    _ = run(e, frames)
    expect(e.mode != .grab)
    // Open the hand, then close it: now it grabs.
    var later: [(Double) -> HandFrame?] = (0..<15).map { _ in { t in frame(x: 0.5, y: 0.5, t: t) } }
    later += (0..<8).map { _ in { t in frame(x: 0.5, y: 0.5, fingers: fist, t: t) } }
    _ = run(e, later, start: 1)
    expect(e.mode == .grab)
}

/// Recorded: closing into a fist passes through a pinch while middle and ring curl. No click.
func closingThroughPinchDoesNotClick() {
    let e = GestureEngine()
    let curling: [Double] = [0.36, 0.25, 0.25, 0.30]
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in still(0.6) }
    frames += (0..<4).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.08, tips: curling, t: t) } }
    frames += (0..<4).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.5, tips: [0.25, 0.24, 0.24, 0.25], t: t) } }
    let out = run(e, frames)
    expect(!out.contains(.click))
}

func closingIntoFistDoesNotClick() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in { t in frame(x: 0.5, y: 0.5, t: t) } }
    frames += (0..<3).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.05, t: t) } }
    frames += (0..<10).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.05, fingers: fist, t: t) } }
    frames += (0..<5).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.8, t: t) } }
    let out = run(e, frames)
    expect(!out.contains(.click))
    expect(!out.contains(.rightClick))
}

func twoFingersTalk() {
    let e = GestureEngine()
    let two = [true, true, false, false]
    var frames: [(Double) -> HandFrame?] = (0..<10).map { i in { t in
        frame(x: 0.5 + Double(i) * 0.01, y: 0.5, fingers: two, t: t)
    } }
    frames += (0..<5).map { _ in { t in frame(x: 0.6, y: 0.5, t: t) } }
    let out = run(e, frames)
    expect(out.filter { $0 == .talkStart }.count == 1)
    expect(out.filter { $0 == .talkEnd }.count == 1)
    expect(abs(moves(out).x) < 0.03)  // the pointer stays while talking
}

func filterPassesConstantValue() {
    var f = OneEuroFilter(minCutoff: 1, beta: 0)
    for i in 0..<10 { expect(f.filter(3, at: Double(i) / 30) == 3) }
}

func filterSmoothsNoise() {
    var f = OneEuroFilter(minCutoff: 1, beta: 0)
    var maxOut = 0.0
    for i in 0..<60 {
        let noisy = i.isMultiple(of: 2) ? 1.0 : -1.0
        maxOut = max(maxOut, abs(f.filter(noisy, at: Double(i) / 30)))
    }
    expect(maxOut <= 1)
    expect(abs(f.filter(1, at: 2.0)) < 0.5)
}

func accelerationGrowsWithSpeed() {
    let a = PointerAcceleration()
    let slow = a.points(for: Vec2(0.002, 0), dt: 1.0 / 30)
    let fast = a.points(for: Vec2(0.05, 0), dt: 1.0 / 30)
    expect(fast.x / 0.05 > slow.x / 0.002)
}

func tremorDoesNotMovePointer() {
    let a = PointerAcceleration()
    expect(a.points(for: Vec2(0.0001, 0), dt: 1.0 / 30) == .zero)
}


/// The way people pinch: index bent to meet the thumb, the other fingers curled.
private let naturalPinch = [0.29, 0.18, 0.18, 0.18]

func naturalPinchClicks() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<4).map { _ in { t in frame(x: 0.5, y: 0.5, t: t) } }
    frames += (0..<5).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.05, tips: naturalPinch, t: t) } }
    frames += (0..<4).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.8, tips: [0.33, 0.25, 0.22, 0.22], t: t) } }
    let out = run(e, frames)
    expect(out.filter { $0 == .click }.count == 1)
    expect(e.mode != .grab)
}

func naturalPinchHoldRightClicks() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in { t in frame(x: 0.5, y: 0.5, t: t) } }
    // Noisy: one frame in six reads the fingertips apart.
    frames += (0..<40).map { i in { t in frame(x: 0.5, y: 0.5, pinch: i % 6 == 5 ? 0.4 : 0.05, tips: naturalPinch, t: t) } }
    frames += (0..<4).map { _ in { t in frame(x: 0.5, y: 0.5, pinch: 0.8, t: t) } }
    let out = run(e, frames)
    expect(out.filter { $0 == .rightClick }.count == 1)
    expect(!out.contains(.click))
}

func relaxedHandDoesNotGrab() {
    let e = GestureEngine()
    let relaxed = [0.30, 0.27, 0.26, 0.25]
    let out = run(e, (0..<30).map { i in { t in frame(x: 0.4 + Double(i) * 0.005, y: 0.5, tips: relaxed, t: t) } })
    expect(e.mode == .hover)
    expect(scrolls(out) == .zero)
    expect(moves(out).x < -0.05)
}

func briefFistDoesNotGrab() {
    let e = GestureEngine()
    var frames: [(Double) -> HandFrame?] = (0..<3).map { _ in { t in frame(x: 0.5, y: 0.5, t: t) } }
    frames += (0..<3).map { _ in { t in frame(x: 0.5, y: 0.5, fingers: fist, t: t) } }
    frames += (0..<5).map { _ in { t in frame(x: 0.5, y: 0.5, t: t) } }
    _ = run(e, frames)
    expect(e.mode == .hover)
}

