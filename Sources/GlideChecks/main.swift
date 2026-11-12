import Foundation

// Swift Testing finds no tests when only the command-line tools are installed.
// This executable runs the checks instead. Run: swift run GlideChecks

var failures = 0
var current = ""

func expect(_ condition: Bool, line: Int = #line) {
    if !condition {
        failures += 1
        print("  FAIL \(current), Checks.swift:\(line)")
    }
}

let checks: [(String, () -> Void)] = [
    ("firstFrameDoesNotJump", firstFrameDoesNotJump),
    ("handMovingRightInImageMovesPointerLeft", handMovingRightInImageMovesPointerLeft),
    ("handMovingUpInImageMovesPointerUp", handMovingUpInImageMovesPointerUp),
    ("quickPinchIsOneClick", quickPinchIsOneClick),
    ("nearMissPinchDoesNotClick", nearMissPinchDoesNotClick),
    ("pinchProgressRisesAsFingersClose", pinchProgressRisesAsFingersClose),
    ("onePinchFrameIsIgnored", onePinchFrameIsIgnored),
    ("ratioBetweenThresholdsKeepsThePinch", ratioBetweenThresholdsKeepsThePinch),
    ("longStillPinchIsRightClick", longStillPinchIsRightClick),
    ("moveBeforeHoldDrags", moveBeforeHoldDrags),
    ("holdThenMoveDrags", holdThenMoveDrags),
    ("middlePinchRightClicks", middlePinchRightClicks),
    ("middlePinchDoesNotDrag", middlePinchDoesNotDrag),
    ("pinchAndMoveDrags", pinchAndMoveDrags),
    ("lostHandWhileDraggingReleases", lostHandWhileDraggingReleases),
    ("reacquiredHandDoesNotJump", reacquiredHandDoesNotJump),
    ("grabScrolls", grabScrolls),
    ("slowSidewaysGrabScrollsNotSwipes", slowSidewaysGrabScrollsNotSwipes),
    ("spreadSwipeSwitchesDesktopOnce", spreadSwipeSwitchesDesktopOnce),
    ("swingBackDoesNotSwipe", swingBackDoesNotSwipe),
    ("relaxedFastMoveDoesNotSwipe", relaxedFastMoveDoesNotSwipe),
    ("slowOpeningClickIsNotRightClick", slowOpeningClickIsNotRightClick),
    ("closingThroughPinchDoesNotClick", closingThroughPinchDoesNotClick),
    ("wholeHandClickClicks", wholeHandClickClicks),
    ("brushDoesNotClick", brushDoesNotClick),
    ("nearTouchDoesNotClick", nearTouchDoesNotClick),
    ("loweringTwoFingersDoesNotGrab", loweringTwoFingersDoesNotGrab),
    ("slowDriftWhilePinchedDoesNotDrag", slowDriftWhilePinchedDoesNotDrag),
    ("palmHoldPausesAndResumes", palmHoldPausesAndResumes),
    ("relaxedStillHandDoesNotPause", relaxedStillHandDoesNotPause),
    ("closingIntoFistDoesNotClick", closingIntoFistDoesNotClick),
    ("twoFingersTalk", twoFingersTalk),
    ("naturalPinchClicks", naturalPinchClicks),
    ("naturalPinchHoldRightClicks", naturalPinchHoldRightClicks),
    ("relaxedHandDoesNotGrab", relaxedHandDoesNotGrab),
    ("briefFistDoesNotGrab", briefFistDoesNotGrab),
    ("filterPassesConstantValue", filterPassesConstantValue),
    ("filterSmoothsNoise", filterSmoothsNoise),
    ("accelerationGrowsWithSpeed", accelerationGrowsWithSpeed),
    ("tremorDoesNotMovePointer", tremorDoesNotMovePointer),
]

for (name, run) in checks {
    current = name
    let before = failures
    run()
    if failures == before { print("  ok   \(name)") }
}
print(failures == 0 ? "\(checks.count) checks passed" : "\(failures) failures")
exit(failures == 0 ? 0 : 1)
