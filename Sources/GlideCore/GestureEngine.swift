import Foundation

public enum SwipeDirection: Equatable {
    case left, right
}

/// Output of the engine. Distances are in camera units (1.0 = image height),
/// screen oriented: x to the right, y down.
public enum GestureAction: Equatable {
    case move(Vec2)
    /// Take back the pointer moves sent in the last `seconds`. `Vec2` is their sum, reversed.
    /// The app replays the exact pixels it posted, so pointer acceleration does not distort it.
    case undo(Vec2, seconds: Double)
    case press          // left button down, a drag starts
    case release        // left button up, the drag ends
    case click          // left click
    case rightClick
    /// Close the menu a long press opened (Escape). A drag follows, as when you lift an icon on iPhone.
    case dismissMenu
    case scroll(Vec2)
    case swipe(SwipeDirection)  // the direction the open hand swiped
    case talkStart      // two fingers up
    case talkEnd
    /// The open palm was held still: Glide paused (true) or resumed (false).
    case pause(Bool)
}

public enum GestureMode: Equatable {
    case idle    // no hand
    case hover   // open hand, moves the pointer
    case pinch   // thumb on index finger, not yet a click, drag or right-click
    case drag    // pinch moved: left button held
    case grab    // hand closed: the page moves with the hand
    case talk    // two fingers up: dictation
}

public struct GestureConfig {
    /// Pinch starts below this ratio (fingertip distance / hand size). Fingertips must touch.
    /// Recorded in use: a real touch drops to 0.01 to 0.09; near-misses hover at 0.16 to 0.21 and clicked at 0.18.
    public var pinchOn = 0.14
    /// Pinch stops above this ratio. Recorded (session 2): a held drag stays below 0.22,
    /// a resting hand drifts 0.25 to 0.40, so 0.30 sat inside the resting hand and releases came late.
    public var pinchOff = 0.24
    /// pinchOff = pinchOn + this when the pinch distance setting changes.
    public static let releaseGap = 0.10
    /// A touch shorter than this is a brush, not a click. Recorded: clicks touch 0.2 s or more, brushes 0.07 s.
    public var clickMin = 0.12
    /// Fingertips still touch below pinchOn + this. The right-click timer runs only while they touch.
    /// Recorded: a click touches for 0.3 s, then opens slowly over 0.3 to 0.5 s.
    public var touchMargin = 0.03
    /// A pinch that ends with the index below this (and middle and ring curled) closed into a fist.
    /// Recorded: a click ends with the index at 1.14 to 1.17, a hand closing into a fist at 0.77.
    public var closingIndex = 0.95
    /// The approach starts at pinchOn x this value. The cursor ring and settle use it.
    /// 1.7 keeps a resting hand (0.30) out of the approach, so it does not slow the pointer.
    public var approach = 1.7
    /// How much the pointer slows as the fingers close (0 = none, 1 = stops).
    public var settle = 0.8
    /// Frames a pinch must hold before it counts.
    public var enterFrames = 2
    /// Frames the open hand must hold before it counts (leaving a grab or talk).
    public var poseFrames = 3
    /// Frames a grab or two fingers must hold before it counts. Longer, so a passing shape does not start a scroll.
    public var shapeFrames = 5
    /// Frames the fingertips must stay apart before a pinch ends. One noisy frame does not end it.
    public var releaseFrames = 2
    /// Touching fingertips hide each other, so Vision is less sure of them.
    public var tipConfidence = 0.15
    /// Kept for GlideReplay overrides. The drag start now uses `driftTau` and `dragSlop`.
    public var dragDelay = 0.3
    /// A drag starts when the hand moves this far on purpose while pinched. Slow drift does not count:
    /// it fades with `driftTau`. Recorded in the playground: clicks held 1.7 to 8 s drift about 0.03 per second.
    public var dragSlop = 0.04
    /// Seconds over which slow drift fades from the drag test. 0.3 kept 7 of 9 long clicks as clicks
    /// and all 4 drags as drags.
    public var driftTau = 0.3
    /// ...or at once when the palm moves more than this.
    public var dragNow = 0.12
    /// Fingertips held touching and still this long is a right-click, fired while still held, as on iPhone.
    /// The ring at the pointer fills toward it, so a long click shows it coming. Moving on purpose before
    /// that is a drag. A middle-finger pinch also right-clicks, on release.
    /// History: off for a day (2026-11-12) for the middle pinch, which Vision often read as an index pinch.
    public var longPress = 0.9
    /// Kept for GlideReplay overrides; the middle pinch now uses `middleOn`.
    public var middleBias = 0.8
    /// The thumb within this of the middle fingertip is a right-click, wherever the index is.
    /// Recorded: the index tip sits beside the middle tip, so both read close (0.05 to 0.2) in a
    /// middle pinch. Index clicks and drags never brought the thumb within 0.23 of the middle tip.
    public var middleOn = 0.16
    /// ...and the index stays straight (tip-to-wrist ratio above this). Recorded: in a middle pinch the
    /// index reads 1.14 to 1.35; in a whole-hand click every finger curls and the index reads 1.03 or less.
    public var middleIndexStraight = 1.08
    /// ...and the ring finger is not curled. Recorded: real middle pinches read 1.02 or more; a whole hand
    /// opening after a click, or closing to scroll, passes through the thumb at the middle tip with the ring at 0.80 to 0.89.
    public var middleRingOpen = 0.95
    /// Pointer travel to undo at the start of a pinch.
    public var pressRewind = 0.12
    /// A gap without a hand shorter than this keeps the state.
    public var lostTimeout = 0.20
    /// A swipe: an open, spread hand moving fast sideways switches desktop.
    /// Recorded: swipes reach 0.85 to 1.27 camera units per second; pointer moves stay below 0.65.
    /// Recorded 2026-11-12: live caught swipes the replay missed at 0.75, so they sat right at the bar.
    public var swipeSpeed = 0.65
    /// A swipe: sideways travel within the window.
    public var swipeDistance = 0.14
    public var swipeWindow = 0.2
    /// Spread: thumb far from the index (pinch ratio above this)...
    /// Recorded: a fast pointer move with a loose hand read 0.55, swipes 0.65 to 1.0.
    public var spreadThumb = 0.6
    /// ...and index and middle straight (tip-to-wrist ratio above this).
    /// Recorded: a relaxed hand reads 1.14 to 1.30, a swipe 1.37 to 1.5.
    public var spreadFingers = 1.32
    /// After a swipe, the hand swinging back the other way does nothing for this long.
    public var swipeCooldown = 0.8
    /// After a swipe the pointer waits until the hand slows, or this long at most.
    public var swipeSettle = 0.6
    /// The wrist this close to the bottom of the camera view (Vision y, 0 at the bottom): no new hand shape.
    /// Recorded: with the wrist cut off, finger bends read wrong and an open hand read as a fist. False grabs
    /// had the palm at 0.77 to 0.89 down the frame; real scrolls at 0.47 to 0.58.
    public var shapeEdge = 0.12
    /// A new grab ignores hand movement this long. Recorded: closing the hand shifts the palm point
    /// 0.02 to 0.05 in the first 0.2 s, which threw the page 50 to 130 pixels before the person moved.
    public var grabSettle = 0.15
    /// Holding a spread palm still this long pauses or resumes Glide.
    /// Recorded: 1.0 s paused twice by mistake while a person got ready to swipe; 1.5 s did not.
    public var wakeHold = 1.5
    /// "Still" for the wake hold: palm movement per frame below this. A swipe moves 0.03 or more.
    public var wakeStill = 0.004
    public var mirror = true
    public var minConfidence = 0.3
    public var filterMinCutoff = 1.2
    public var filterBeta = 12.0

    public init() {}
}

public final class GestureEngine {
    public var config: GestureConfig
    public var classifier = PoseClassifier()

    public private(set) var mode: GestureMode = .idle
    public private(set) var pose: HandPose = .open
    public private(set) var pinchRatio: Double?
    /// Thumb tip to middle tip over hand size.
    public private(set) var middleRatio: Double?
    /// The current pinch uses the middle finger: it ends in a right-click.
    public private(set) var middlePinch = false
    /// Paused: the hand moves nothing until the palm is held up again.
    public private(set) var paused = false
    /// 0...1 toward a pause or resume.
    public private(set) var wakeProgress = 0.0
    /// 0 with the fingers apart, 1 at the click distance.
    public private(set) var pinchProgress = 0.0
    /// Seconds the current pinch is held.
    public private(set) var pinchHeld = 0.0
    /// 0...1 toward a swipe.
    public private(set) var flingProgress = 0.0
    public private(set) var clicks = 0
    public private(set) var rightClicks = 0
    public private(set) var swipes = 0
    public var isDragging: Bool { mode == .drag }
    /// For tuning: the shape read from this frame, before it settles.
    public private(set) var rawPose: HandPose = .open
    /// For tuning: tip-to-wrist ratios for index, middle, ring, little.
    public private(set) var fingerRatios: [Double?] = [nil, nil, nil, nil]

    private var filter: OneEuroFilter2D
    private var lastPalm: Vec2?
    private var lastSeen: Double?
    private var pinchFrames = 0
    private var wakeStart: Double?
    /// The wrist is at the bottom edge of the camera view this frame.
    private var wristLow = false
    private var grabStart = 0.0
    private var lastNow = 0.0
    /// After a toggle the hand must leave the spread palm before the next one.
    private var wakeNeedsRelease = false
    private var pinchCandidateMiddle = false
    private var middleFrames = 0
    private var poseCandidate: HandPose = .open
    private var poseCount = 0
    private var pinchStart = 0.0
    private var slop = Vec2.zero
    /// Movement during the pinch with slow drift faded out.
    private var intent = Vec2.zero
    private var lastPinchFrame = 0.0
    private var rightFired = false
    private var recentMoves: [(t: Double, d: Vec2)] = []
    /// Pointer moves sent in the last 0.4 s. A swipe takes them back.
    private var sentMoves: [(t: Double, d: Vec2)] = []
    private var swipeMoves: [(t: Double, d: Vec2, spread: Bool)] = []
    private var lastSwipe: (t: Double, direction: SwipeDirection)?
    /// A swipe fired: wait for the hand to slow before the next one.
    private var swipeArmed = true
    private var releaseCount = 0
    /// Frames in a row with the fingertips no longer touching. Two end the right-click chance.
    private var openCount = 0
    /// The fingertips came apart during this pinch: it can still click, never right-click.
    private var opening = false
    /// Talk just ended. Recorded: people lower the two fingers by folding them into a fist,
    /// so a grab can start only after the hand has opened.
    private var grabNeedsOpen = false
    private var openSince: Double?


    public init(config: GestureConfig = GestureConfig()) {
        self.config = config
        filter = OneEuroFilter2D(minCutoff: config.filterMinCutoff, beta: config.filterBeta)
    }

    /// Ends any gesture. Returns a release or a talk end when one is open.
    public func reset() -> [GestureAction] {
        var actions: [GestureAction] = []
        if mode == .drag { actions.append(.release) }
        if mode == .talk { actions.append(.talkEnd) }
        mode = .idle
        pose = .open
        poseCandidate = .open
        poseCount = 0
        filter.reset()
        lastPalm = nil
        lastSeen = nil
        pinchFrames = 0
        pinchHeld = 0
        pinchProgress = 0
        flingProgress = 0
        recentMoves.removeAll()
        swipeMoves.removeAll()
        swipeArmed = true
        grabNeedsOpen = false
        pinchRatio = nil
        middleRatio = nil
        middlePinch = false
        releaseCount = 0
        return actions
    }

    /// Pauses or resumes from the menu or shortcut. Returns a release or talk end when one was open.
    public func setPaused(_ on: Bool) -> [GestureAction] {
        guard on != paused else { return [] }
        paused = on
        wakeStart = nil
        wakeProgress = 0
        return on ? reset() : []
    }

    public func update(_ frame: HandFrame?, now: Double) -> [GestureAction] {
        guard let frame, let palm = palmPoint(frame), let scale = handScale(frame), scale > 0.01 else {
            wakeStart = nil
            wakeProgress = 0
            if let seen = lastSeen, now - seen < config.lostTimeout { return [] }
            return mode == .idle ? [] : reset()
        }
        lastSeen = now
        lastNow = now

        let filtered = filter.filter(palm, at: frame.time)
        var delta = Vec2.zero
        if let last = lastPalm {
            let raw = filtered - last
            delta = Vec2(config.mirror ? -raw.x : raw.x, -raw.y)
        }
        lastPalm = filtered

        fingerRatios = classifier.ratios(frame)

        wristLow = (frame.point(.wrist, minConfidence: config.minConfidence)?.y ?? 1) < config.shapeEdge
        // Wrist cut off: keep the current shape rather than read a new one from bent-looking fingers.
        let raw = wristLow ? pose : classifier.classify(ratios: fingerRatios)
        rawPose = raw
        settlePose(raw)
        pinchRatio = ratio(frame, .thumbTip, .indexTip, scale)
        middleRatio = ratio(frame, .thumbTip, .middleTip, scale)
        let closest = [pinchRatio, middleRatio].compactMap { $0 }.min()
        if raw != .open {
            pinchProgress = 0
        } else if let r = closest {
            let start = config.pinchOn * config.approach
            pinchProgress = min(1, max(0, (start - r) / (start - config.pinchOn)))
        } else {
            pinchProgress = 0
        }

        // Spread palm held still: pause or resume. Checked in every state, so it also wakes Glide.
        if let toggle = wakeStep(delta, raw: raw, now: now) { return toggle }
        if paused {
            mode = .idle
            pinchProgress = 0
            return []
        }

        if mode == .idle {
            mode = .hover
            return []
        }

        switch mode {
        case .pinch:
            pinchHeld = now - pinchStart
            // Closing into a fist on the way: a grab, never a click.
            if pose == .fist { return enterGrab() }
            if released() {
                let held = pinchHeld
                let middle = middlePinch
                mode = .hover
                pinchHeld = 0
                middlePinch = false
                // Recorded in use: a whole-hand click curls every finger, then opens wide. That clicks.
                if rightFired || held < config.clickMin || closingIntoFist(raw) { return [] }
                if middle {
                    rightClicks += 1
                    return [.rightClick]
                }
                clicks += 1
                return [.click]
            }
            // An index pinch that reaches the middle fingertip becomes a right-click. One frame is enough:
            // Vision often loses the hand in this pose (recorded: 1 frame in 6), and clicks never came within 0.23.
            if !middlePinch, let m = middleRatio, m < config.middleOn, middleShape() { middlePinch = true }
            // A middle-finger pinch is a right-click when it opens. It never drags.
            if middlePinch { return [] }
            if rightFired {
                // Held past the right-click, then moved on purpose: close the menu and drag, like iPhone.
                slop += delta
                let dt = max(0, now - lastPinchFrame)
                lastPinchFrame = now
                intent = (intent + delta) * max(0, 1 - dt / config.driftTau)
                if intent.length > config.dragSlop * 1.5 {
                    mode = .drag
                    rightFired = false
                    return [.dismissMenu, .press, .move(slop)]
                }
                return []
            }
            if let r = pinchRatio {
                openCount = r > config.pinchOn + config.touchMargin ? openCount + 1 : 0
                if openCount >= 2 { opening = true }
            }
            slop += delta
            let dt = max(0, now - lastPinchFrame)
            lastPinchFrame = now
            intent = (intent + delta) * max(0, 1 - dt / config.driftTau)
            if intent.length > config.dragSlop {
                mode = .drag
                // The whole movement since the pinch started, so the object follows the hand from where it was.
                return [.press, .move(slop)]
            }
            if !opening && pinchHeld >= config.longPress && intent.length <= config.dragSlop {
                rightFired = true
                rightClicks += 1
                return [.rightClick]
            }
            return []

        case .drag:
            if released() {
                mode = .hover
                return [.release]
            }
            return delta == .zero ? [] : [.move(delta)]

        case .grab:
            if pose != .fist {
                mode = .hover
                return []
            }
            if lastNow - grabStart < config.grabSettle { return [] }
            return delta == .zero ? [] : [.scroll(delta)]

        case .talk:
            if pose != .two {
                mode = .hover
                grabNeedsOpen = true
                return [.talkEnd]
            }
            return []

        case .hover, .idle:
            // Recorded: folding down from two fingers passes through 3 open frames. Open means 0.25 s.
            if pose == .open {
                if openSince == nil { openSince = now }
                if now - openSince! >= 0.25 { grabNeedsOpen = false }
            } else {
                openSince = nil
            }
            switch pose {
            case .fist: return grabNeedsOpen ? [] : enterGrab()
            case .two:
                mode = .talk
                return [.talkStart]
            case .open: break
            }
            // Hold the pointer while a new hand shape is not yet confirmed.
            if raw != .open {
                swipeMoves.removeAll()
                return []
            }
            if let swipe = swipeStep(delta, now: now) { return swipe }

            // Which fingertip the thumb touches: index clicks and drags, middle right-clicks.
            let i = pinchRatio ?? .infinity, m = middleRatio ?? .infinity
            let touch: Bool?   // true: middle, false: index, nil: none
            if m < config.middleOn && middleShape() {
                touch = true
            } else if i < config.pinchOn {
                touch = false
            } else {
                touch = nil
            }
            if let touch {
                pinchFrames = touch == pinchCandidateMiddle ? pinchFrames + 1 : 1
                pinchCandidateMiddle = touch
            } else {
                pinchFrames = 0
            }
            if pinchFrames >= config.enterFrames {
                middlePinch = pinchCandidateMiddle
                middleFrames = 0
                pinchFrames = 0
                releaseCount = 0
                openCount = 0
                opening = false
                swipeMoves.removeAll()
                flingProgress = 0
                mode = .pinch
                pinchStart = now
                pinchHeld = 0
                slop = .zero
                intent = .zero
                lastPinchFrame = now
                rightFired = false
                let rewind = rewindMove(now: now)
                recentMoves.removeAll()
                return rewind == .zero ? [] : [.undo(rewind, seconds: config.pressRewind)]
            }
            // Hold the pointer while a pinch is not yet confirmed.
            if pinchFrames > 0 { return [] }
            // The pointer slows as the fingers close, so it settles on the target.
            return hoverStep(delta * (1 - config.settle * pinchProgress), now: now)
        }
    }

    // MARK: - Steps

    /// Returns the toggle when the hold completes, nil otherwise.
    private func wakeStep(_ delta: Vec2, raw: HandPose, now: Double) -> [GestureAction]? {
        let spread = raw == .open
            && (pinchRatio ?? 0) > config.spreadThumb
            && (fingerRatios[0] ?? 0) > config.spreadFingers
            && (fingerRatios[1] ?? 0) > config.spreadFingers
        let idle = paused || mode == .hover || mode == .idle
        guard spread, idle, delta.length < config.wakeStill else {
            wakeStart = nil
            wakeProgress = 0
            if !spread { wakeNeedsRelease = false }
            return nil
        }
        if wakeNeedsRelease { return nil }
        if wakeStart == nil { wakeStart = now }
        let held = now - wakeStart!
        // Show progress only after a short moment, so a passing open hand shows nothing.
        wakeProgress = held < 0.25 ? 0 : min(1, (held - 0.25) / (config.wakeHold - 0.25))
        guard held >= config.wakeHold else { return nil }
        wakeStart = nil
        wakeProgress = 0
        wakeNeedsRelease = true
        var out = paused ? [] : reset()
        paused.toggle()
        if paused { mode = .idle }
        out.append(.pause(paused))
        return out
    }

    private func enterGrab() -> [GestureAction] {
        mode = .grab
        grabStart = lastNow
        pinchHeld = 0
        swipeMoves.removeAll()
        flingProgress = 0
        return []
    }

    /// An open, spread hand moving fast sideways: switch desktop, like a trackpad swipe.
    /// Returns the swipe, plus a move that puts the pointer back where the swipe began.
    /// Returns [] while the hand is still moving after a swipe, nil when this frame is not part of a swipe.
    private func swipeStep(_ delta: Vec2, now: Double) -> [GestureAction]? {
        let spread = !wristLow
            && (pinchRatio ?? 0) > config.spreadThumb
            && (fingerRatios[0] ?? 0) > config.spreadFingers
            && (fingerRatios[1] ?? 0) > config.spreadFingers
        swipeMoves.append((now, delta, spread))
        swipeMoves.removeAll { now - $0.t > config.swipeWindow }

        let travel = swipeMoves.reduce(Vec2.zero) { $0 + $1.d }
        let span = max(now - (swipeMoves.first?.t ?? now), 1.0 / 30)
        let vx = travel.x / span, vy = travel.y / span
        let sideways = abs(vx) > 1.5 * abs(vy)
        let spreadFrames = swipeMoves.filter(\.spread).count

        // After a swipe, hold the pointer until the hand slows down.
        if !swipeArmed {
            let slow = abs(vx) < config.swipeSpeed * 0.4 && abs(vy) < config.swipeSpeed * 0.4
            if slow || now - (lastSwipe?.t ?? 0) > config.swipeSettle {
                swipeArmed = true
                swipeMoves.removeAll()
            }
            flingProgress = swipeArmed ? 0 : 1
            return swipeArmed ? nil : []
        }
        flingProgress = sideways && spreadFrames > 0 ? min(1, abs(vx) / config.swipeSpeed) : 0

        guard sideways, spreadFrames >= 2,
              abs(vx) > config.swipeSpeed, abs(travel.x) > config.swipeDistance else { return nil }
        let direction: SwipeDirection = vx < 0 ? .left : .right
        // The hand swinging back after a swipe is not a new swipe.
        if let last = lastSwipe, last.direction != direction, now - last.t < config.swipeCooldown { return nil }

        swipes += 1
        lastSwipe = (now, direction)
        swipeArmed = false
        flingProgress = 1
        // The pointer moved with the swipe: put it back.
        let back = sentMoves.reduce(Vec2.zero) { $0 + $1.d }
        sentMoves.removeAll()
        swipeMoves.removeAll()
        recentMoves.removeAll()
        return back == .zero ? [.swipe(direction)] : [.undo(back * -1, seconds: 0.4), .swipe(direction)]
    }

    /// A right-click shape: index straight, ring open. A whole hand curling is not one.
    private func middleShape() -> Bool {
        (fingerRatios[0] ?? 0) > config.middleIndexStraight && (fingerRatios[2] ?? 0) > config.middleRingOpen
    }

    /// The fingertips came apart because the whole hand closed, not because it opened.
    private func closingIntoFist(_ raw: HandPose) -> Bool {
        if raw == .fist { return true }
        guard let i = fingerRatios[0], let m = fingerRatios[1], let r = fingerRatios[2] else { return false }
        return i < config.closingIndex && m < classifier.curledRatio && r < classifier.curledRatio
    }

    private func released() -> Bool {
        guard let r = middlePinch ? middleRatio : pinchRatio else { return false }
        releaseCount = r > config.pinchOff ? releaseCount + 1 : 0
        return releaseCount >= config.releaseFrames
    }

    private func settlePose(_ raw: HandPose) {
        if raw == poseCandidate {
            poseCount += 1
        } else {
            poseCandidate = raw
            poseCount = 1
        }
        if poseCount >= (raw == .open ? config.poseFrames : config.shapeFrames) { pose = raw }
    }

    private func hoverStep(_ delta: Vec2, now: Double) -> [GestureAction] {
        recentMoves.append((now, delta))
        recentMoves.removeAll { now - $0.t > config.pressRewind }
        sentMoves.append((now, delta))
        sentMoves.removeAll { now - $0.t > 0.4 }
        return delta == .zero ? [] : [.move(delta)]
    }

    private func rewindMove(now: Double) -> Vec2 {
        var sum = Vec2.zero
        for m in recentMoves where now - m.t <= config.pressRewind { sum += m.d }
        return sum * -1
    }

    // MARK: - Geometry

    /// Midpoint of the wrist and the middle-finger knuckle. Fingertips do not move it.
    private func palmPoint(_ f: HandFrame) -> Vec2? {
        guard let w = f.point(.wrist, minConfidence: config.minConfidence),
              let m = f.point(.middleMCP, minConfidence: config.minConfidence) else { return nil }
        return (w + m) * 0.5
    }

    private func handScale(_ f: HandFrame) -> Double? {
        guard let w = f.point(.wrist, minConfidence: config.minConfidence),
              let m = f.point(.middleMCP, minConfidence: config.minConfidence) else { return nil }
        return (m - w).length
    }

    private func ratio(_ f: HandFrame, _ a: HandFrame.Joint, _ b: HandFrame.Joint, _ scale: Double) -> Double? {
        guard let pa = f.point(a, minConfidence: config.tipConfidence),
              let pb = f.point(b, minConfidence: config.tipConfidence) else { return nil }
        return (pa - pb).length / scale
    }
}
