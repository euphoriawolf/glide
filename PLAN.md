# Glide plan

Glide is a Mac app. You control the Mac with your hand and your voice. It is a side project for fun.

## Design rules

1. Copy the mouse and the trackpad. Do not invent new input. The only new input is dictation, with a better speech model than the keyboard has.
2. Keep the hand low, on the desk or in the lap. Do not make the user lift the arm.
3. The hand moves the pointer like a finger on a trackpad. The hand does not point at the screen.
4. Show what Glide will do before it does it. A ring around the pointer closes as the fingers close.
5. When tracking is weak, do nothing. A wrong click is worse than no click.
6. Show state with light and motion, not with words.

The tick ring in setup comes from Face ID enrollment. The gesture lessons come from visionOS "tap your fingers together" onboarding.

## Prototype

The design prototype is `design/glide-prototype.html`. It shows the notch pill, the gestures, voice, low light and the first run. Live copy: https://claude.ai/artifact/FZsrkDk9mYZc1RLrZbpXzC

The prototype still shows the first gesture set. The app now uses grab to scroll, an open-hand swipe to switch desktop and ✌️ to talk.

## Steps

| # | Step | Status |
|---|---|---|
| 1 | Webcam hand tracking: mouse and trackpad gestures | Built 2026-11-11, tuning |
| 2 | Apple Watch input: wrist gestures, no camera | Next |
| 3 | Voice: ✌️ or fn, on-device `SpeechTranscriber`, commands, Apple Intelligence clean-up | Built 2026-11-11 |
| 4 | Status pill near the notch, pointer feedback | Built 2026-11-11 |
| 5 | Leap Motion Controller 2 backend for dark rooms | Later |
| 6 | Hand and voice together: "move this to the left" | Later |

## Gestures

| Hand | Mouse or trackpad action |
|---|---|
| Open hand, move it | Move the pointer |
| Thumb touches index finger, then opens | Click |
| Two quick pinches | Double-click |
| Pinch and hold until the ring fills (or pinch thumb and middle finger) | Right-click |
| Pinch and move | Drag |
| Close the hand (grab), move | Scroll. The page moves with the hand. |
| Spread the hand, swipe left or right | Switch desktop |
| Index and middle finger up (✌️), talk, lower the hand | Dictation into the focused text field |
| Hold fn, talk, release | Dictation, same as ✌️ |
| Hand out of view | The pointer stops and shows a dashed ring that fades |
| Control + Option + Space | Turn Glide on or off |
| Control + Option + P | Show or hide the tracking preview |

Desktop switches (swipe) use the Control + arrow shortcuts from System Settings > Keyboard > Keyboard Shortcuts > Mission Control. They must be on.

## Feedback on the screen

- A ring around the pointer appears as thumb and index finger close. It gets smaller and brighter, and at the click distance it is a small solid ring. You see a click before it happens.
- A click sends one ripple from the pointer. A right-click sends two. A drag shows a solid dot.
- An index pinch shows a small filled ring. A middle pinch shows a wider open ring: it right-clicks on release.
- When the hand nears an edge of the camera view, a crescent lights up on that side of a ring around the pointer. All feedback is at the pointer, where the eyes are. (A glow at the screen edge was tried first. It was not seen.)
- When the hand leaves the view, a dashed ring stays at the pointer for 1.6 s: the pointer is parked.
- A swipe shows an arrow at the pointer.
- Dictation with no text field in focus: the pill says "Click a text field first".
- Dictation: a black pill grows out of the notch, with a waveform and the words as you say them.

## Pointer feel

Mouse drivers do more than move the pointer. Glide copies three of their methods:

1. **Acceleration.** Slow hand movement gives a low gain for precision. Fast movement gives a high gain to cross the screen.
2. **Tremor filter.** Hand movement below 0.006 camera units per second does not move the pointer.
3. **Settle before a click.** As the fingers close, the pointer slows, up to 80%. At the start of a pinch, the pointer goes back to its position 0.12 s before. The click lands where you aimed.

The pinch needs the fingertips to touch: a distance below 0.15 of the hand size. Change it in Settings > Pinch distance.

## Setup

- Steps: camera, Accessibility, microphone, then practice: raise a hand, click, right-click, drag, grab to scroll, swipe, dictation.
- Back goes to the step before, and skips permissions that are granted. Click a page dot to go to any lesson. Learn Gestures in the menu opens the lessons after setup.
- A tick ring around the live view fills as Glide sees the gesture, as in Face ID setup. A vector animation beside it shows the gesture. With no progress for 7 s, a hint shows.
- During practice, Glide does not click, scroll or type.
- The hand that clicks first in setup becomes the primary hand. Glide ignores the other hand.
- On the last screen Glide is on, so a pinch presses Done. The screen closes by itself after 8 s.
- The setup opens again when a permission is missing.

## Settings

Settings follow System Settings > Mouse: tracking speed, pinch distance, scroll speed, natural scrolling, primary hand, low-light boost, the dictation key (fn or Right Option), clean-up on or off, and words to know.

## How it works

1. `AVCaptureSession` gets 640 x 480 frames from the camera.
2. In a dark room, Glide raises the exposure and the gamma of the frame before Vision reads it.
3. `VNDetectHumanHandPoseRequest` finds 21 joints of up to two hands. Glide follows one: the hand nearest to the last palm point, never a hand more than 0.25 away, never the hand of the other side.
4. The palm point is the midpoint of the wrist and the middle-finger knuckle. The fingertips do not move it.
5. A One Euro filter removes jitter from the palm point.
6. `PoseClassifier` finds the hand shape from each finger's tip-to-wrist distance over its middle-joint-to-wrist distance:
   - Grab: index, middle and ring folded into the palm (below 0.92). A pinching index is bent (about 1.0 to 1.15), not folded, so a pinch never reads as a grab. An earlier rule (any 3 of 4 fingers curled) read natural pinches and relaxed hands as grabs: clicks failed and scroll started by itself.
   - Two fingers: index and middle above 1.18, ring and little below 1.0.
   - A grab or two fingers must hold for 5 frames (about 0.17 s). The open hand must hold for 3.
7. `GestureEngine` turns shapes and pinches into mouse actions. A pinch waits: a release is a click and movement on purpose is a drag. A middle-finger pinch is a right-click on release. A release needs 2 frames with the fingertips apart, so one noisy frame does not end a right-click. Touching fingertips are accepted at confidence 0.15, because they hide each other.
8. A swipe: a spread hand (thumb far from the index, index and middle straight) with sideways speed above 0.75 camera units per second and travel above 0.14 within 0.2 s. The pointer goes back to where the swipe started. A swing back in the other direction within 0.8 s does nothing.
9. `CGEvent` posts the pointer, button, scroll and key events. A swipe sends Control + left or right arrow.
10. Dictation: `AVAudioEngine` sends the microphone to `SpeechAnalyzer` with `SpeechTranscriber` (preset `progressiveTranscription`), or `DictationTranscriber` when the language needs it. The text before the cursor and the "words to know" go in as `contextualStrings`. Then "new line", "next line" and "new paragraph" become line breaks. Then the on-device Apple Intelligence model (`LanguageModelSession`) fixes misheard words, punctuation and filler, with a 3 s limit; Glide drops its answer when the length changes by more than half. Glide pastes the text with Command + V and puts the old clipboard back.
11. Dictation starts only when Accessibility reports a text input in focus. When an app does not report its focus, Glide allows it. A tap shorter than 0.3 s, or fn with another key, cancels.

Tuning values: `Sources/GlideCore/GestureEngine.swift`, `PointerAcceleration.swift` and `HandPose.swift`.

## Build and run

You need macOS 26 or later (for `DictationTranscriber`) and the Xcode command-line tools.

```bash
cd ~/Documents/Work/glide && ./scripts/build-app.sh && open build/Glide.app
```

```bash
cd ~/Documents/Work/glide && swift run GlideChecks
```

`GlideChecks` runs 25 checks on the gesture logic. Swift Testing finds no tests when only the command-line tools are installed, thus the checks are an executable.

## Testing on a real hand

Synthetic hands in `GlideChecks` test the logic, but they move the way the code expects. A real hand does not: the first recording showed the palm moves 0.015 to 0.14 during a quick click, so clicks turned into drags. Thus Glide tests on recordings of a real hand.

1. Open the Glide menu: Record Test Session. A window gives 8 prompts, about 90 seconds in all: move without clicking, click 5 times, right-click 3 times, drag 3 times, grab and scroll, swipe twice, talk twice, rest. Nothing gets clicked during the session.
2. Glide saves `~/Library/Logs/Glide/session-<time>/`: `video.mov` (the raw camera frames) and `labels.json` (when each prompt ran).
3. Replay it:

```bash
cd ~/Documents/Work/glide && swift run GlideReplay ~/Library/Logs/Glide/session-<time>
```

Playground (Glide menu: Playground…): a small desktop with real controls. Glide works on it as usual, so the test goes through the same mouse events as any app. It has three circles of different sizes and a Save button, a Notes file with a right-click menu, folders to drag into Archive, a text box for dictation, a list of 60 rows, and two desktops (a swipe changes the playground desktop, not the real one). Click Record to step through 11 tasks, then free play, then Stop. The session folder gets `video.mov`, `labels.json` (each task as `kind:id`) and `events.json`. That file keeps what each object saw (`miss` is a click on nothing, `dragEnd` is a drop outside Archive) and what Glide did, on the video's clock. GlideReplay scores each task by its rules in `PlaygroundScript` and lists the live clicks on nothing.

GlideReplay runs the same `HandReader` (Vision) and `GestureEngine` as the app on every frame, and compares the result with each prompt: for example "click 4, want 5" or "grab 2, want 0" in the "move" step. `--verbose` prints each event with its time. Any threshold can change without a rebuild, for example `--pinchOn 0.2 --dragSlop 0.04`.

Changes from the fifth playground run (2026-11-12):
- Right-click is a long press again, done as on iPhone: the ring at the pointer grows and fills, and the right-click fires at 0.9 s while still held. Moving on purpose before that is a drag. Moving on purpose after it closes the menu (Escape) and starts a drag from the pinch point, as when you lift an icon on iPhone. The middle pinch still right-clicks on release. Reason: the person felt the middle pinch was often taken for a click, because Vision reads the index tip beside the middle tip.
- Grab: movement in the first 0.15 s is ignored (closing the hand shifted the palm point 0.02 to 0.05, a jolt of 50 to 130 pixels). Fast strokes scroll up to 2.5 times farther. When the hand opens during a fast stroke, the page coasts and slows over about 0.35 s, as after a trackpad flick.
- Swipe: the speed bar is 0.65 (was 0.75), because live caught swipes the replay missed. The prompts say which way to swipe. A swipe toward a desktop that is not there makes the playground bounce.
- How headsets do it, for reference: Vision Pro and iPhone use one pinch and let time and motion decide (tap, hold for the menu, move to drag). Trackpads use extra fingers, which a camera cannot tell apart reliably.

Edge calibration, from the first playground run with edge tasks (2026-11-12):
- All four screen corners were reachable. Both top corners pushed the hand out of the top of the camera view, with the palm 0.12 to 0.15 below the edge (the fingertips are higher than the palm point). Fast pointer moves now have more reach (maximum gain 7000, was 5200, reached at a hand speed of 0.7, was 0.9). Slow, precise moves are unchanged.
- The hand worked in x 0.50 to 0.72 and y 0.27 to 0.82 of the frame (as the person sees it). 8 of 10 exits were by the bottom. The hand left with the palm 0.05 to 0.15 from the top or bottom edge, and Vision dropped it from about 0.2.
- The out-of-view arc at the pointer now starts at 0.32 from the top and bottom edges (full at 0.14), and at 0.22 from the sides (full at 0.08). It started at 0.18 before, so it barely showed before the hand was gone.
- With the wrist within 0.12 of the bottom edge, no new hand shape starts (fist, two fingers, swipe). A cut-off wrist makes an open hand read as a fist: false grabs had the palm at 0.77 to 0.89 down the frame, real scrolls at 0.47 to 0.58. A shape already in progress continues.

Changes from the third playground recording (2026-11-12):
- Right-click: the thumb within 0.16 of the middle fingertip, with the index straight (above 1.08) and the ring finger open (above 0.95). The index tip sits beside the middle tip, so both read close in a middle pinch: the old rule (middle clearly closer than index) missed most attempts. Index clicks and drags never brought the thumb within 0.23 of the middle tip. A whole hand curling (a whole-hand click, or closing to scroll) passes the thumb by the middle tip with the ring finger at 0.80 to 0.89, so the ring rule keeps it out. One frame is enough inside a pinch, because Vision often loses the hand in this pose. In six recordings, right-clicks now fire only in the right-click tasks.
- Pause: hold an open, spread palm still for 1.5 s to pause or resume. 1.0 s paused twice by mistake while getting ready to swipe. The menu and ⌃⌥Space use the same pause.
- Transcription: listening starts in 0.6 s. The clean-up pass has a real 1.2 s limit (it took 7.2 s cold), and the model warms only after the mic is live (warming first delayed listening by 6 s). A hidden Edit menu lets ⌘V paste into Glide's own windows. Each attempt writes step timings to `~/Library/Logs/Glide/dictation.log`. `--dictation-test` listens for 8 s and logs the text; run `say` beside it to test without a person.
- Edges: the playground has 6 more tasks: reach each screen corner (a glow marks it), take the hand out of view to the side, and lower it out of view. Glide logs each hand lost and found with its last position. GlideReplay prints where the palm works in the camera frame, brief dropouts by nearest edge, and each exit. First result: the palm worked at x 0.51 to 0.76 and y 0.36 to 0.89 (as seen by the person), 70 brief dropouts happened 0.16 to 0.24 from the bottom and right edges, and all 5 exits were by the bottom.

Changes from the first playground recording (2026-11-12): right-click is a thumb and middle finger pinch, and it fires when the fingers open. A long hold no longer right-clicks, because clicks were held up to 4 s still and a right-click was held 1.8 s. A middle pinch needs the thumb 20% closer to the middle tip than to the index tip, and it never drags. A drag starts after 0.04 of movement on purpose: slow drift while pinched fades over 0.3 s, so a long click does not become a drag. In about 6 minutes of earlier recordings, no middle pinch fired by mistake.

Values set from a recording of everyday use (2026-11-11, menu: Record While Using): a pinch starts at 0.14, because a real touch drops to 0.01 to 0.09 and near-misses at 0.16 to 0.21 clicked. A touch shorter than 0.12 s is a brush and does not click. The rule that skipped a click when the other fingers moved was removed: in everyday use, clicks curl the whole hand and then open it wide. Drag events now carry the distance moved, as real mouse events do.

Values set from the third recording (2026-11-11): a right-click needs 1.0 s of touch, because slow clicks touch for 0.3 to 0.7 s and right-click holds last 1.9 to 3.3 s. A swipe needs a wider spread (thumb ratio above 0.6, index and middle above 1.32), because a fast pointer move with a loose hand read 0.55 and 1.27. After talking, a grab can start only when the hand has been open for 0.25 s, because people lower two fingers by folding them into a fist. Both recordings pass every step.

Values set from the second recording (2026-11-11): a pinch ends at 0.24, because a resting hand reads 0.25 to 0.40 and a held drag stays below 0.22. A right-click needs the fingertips to touch (below 0.21). A click shows touch for 0.3 s and then opens slowly. A pinch does not click when the hand closes into a fist (index below 0.95, middle and ring curled). All steps pass. `--trace 12-19` prints each frame, and `--dump frames.csv` writes every frame for analysis.

Values set from the first recording (2026-11-11): pinch starts at 0.18 (touching fingertips read 0.06 to 0.22), pinch ends at 0.30 (a held drag reaches 0.26), a drag needs 0.3 s and 0.03 of palm travel or 0.12 at once, and a grab needs index, middle and ring below 0.85 with a mean below 0.8.

## Signing

macOS keeps a privacy permission only while the app signature stays the same. An ad hoc signature changes with each build, so a rebuild lost the Accessibility permission.

Run this one time:

```bash
cd ~/Documents/Work/glide && ./scripts/setup-signing.sh
```

The script makes a self-signed certificate in its own keychain file, `.signing/glide.keychain-db`. Your login keychain does not change. Git ignores `.signing/`. After that, `build-app.sh` signs with this certificate, and permissions stay across rebuilds. The certificate is not trusted, and codesign does not need it to be.

An Accessibility entry keeps the signature from the time it was made. A switch turned off and on again does not update it. If the prompt comes back while the switch is on, remove Glide from the list with the minus button, then click Allow again.

To sign, codesign must find the keychain in the search list. `build-app.sh` adds the keychain, signs, then puts the old list back.

## Known limits

- Vision sees the hand in 2D. When the fingers point at the camera, distances look shorter, and a pinch can come early. Keep the palm toward the screen.
- If fn opens the emoji panel, set System Settings > Keyboard > Press fn key to > Do Nothing.
- In a very dark room the webcam fails. The boost helps a little. Step 5 and step 2 solve this.

## Step 2: Apple Watch (next)

The Watch has motion sensors and needs no light. Thus it works in any room.

### Plan

1. A watchOS app reads `CMDeviceMotion` at 50 to 100 Hz.
2. A workout session keeps the app active when the wrist is down.
3. Double Tap on Series 9, Ultra 2 and later triggers the primary action through `handGestureShortcut(.primaryAction)`. Glide uses it as a click.
4. Wrist tilt gives the scroll. Wrist roll can move the pointer.
5. The Watch sends events to the Mac. The Mac side uses the same `PointerOutput` as step 1.

### Check first

- Building a watchOS app needs the full Xcode, not only the command-line tools. This Mac has only the tools now.
- watchOS limits low-level network connections (Apple TN3135). Find out if the Watch can talk to the Mac directly. If it cannot, the path is Watch to iPhone through `WatchConnectivity`, then iPhone to Mac on the local network.
- Measure the delay from the wrist to the Mac. A click must arrive in less than 150 ms to feel direct.
- Find out which Watch model you have. Double Tap needs Series 9, Ultra 2 or later.
