import AVFoundation
import Foundation
import GlideCore
import GlideVision
import Vision

// Runs a recorded test session through the same Vision reader and gesture engine as the app,
// then compares what Glide detected with what each prompt asked for.
//
// Usage: swift run GlideReplay <session folder> [--verbose] [--name value ...]
// Names: pinchOn pinchOff dragSlop dragDelay dragNow longPress shapeFrames poseFrames releaseFrames
//        swipeSpeed swipeDistance spreadThumb spreadFingers touchMargin approach foldedRatio foldedMean extendedRatio curledRatio primary(left|right|either)

var args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first else {
    print("Usage: GlideReplay <session folder> [--verbose] [--name value ...]")
    exit(2)
}
args.removeFirst()
let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
var verbose = false
var trace: (Double, Double)?
var dump: FileHandle?
var overrides: [String: String] = [:]
var i = 0
while i < args.count {
    if args[i] == "--verbose" {
        verbose = true
        i += 1
    } else if args[i] == "--dump", i + 1 < args.count {
        // --dump frames.csv: every frame, for analysis.
        FileManager.default.createFile(atPath: args[i + 1], contents: nil)
        dump = FileHandle(forWritingAtPath: args[i + 1])
        dump?.write("t,segment,mode,raw,pinch,index,middle,ring,little,palmX,palmY,scale,thumbMiddle\n".data(using: .utf8)!)
        i += 2
    } else if args[i] == "--trace", i + 1 < args.count {
        // --trace 12-26: one line per frame between these seconds.
        let p = args[i + 1].split(separator: "-").compactMap { Double($0) }
        if p.count == 2 { trace = (p[0], p[1]) }
        i += 2
    } else if args[i].hasPrefix("--"), i + 1 < args.count {
        overrides[String(args[i].dropFirst(2))] = args[i + 1]
        i += 2
    } else {
        i += 1
    }
}

// MARK: Engine, with the app's saved settings, then the overrides

let saved = UserDefaults(suiteName: "com.derrickikenga.glide")
let engine = GestureEngine()
let reader = HandReader()
if let pinch = saved?.object(forKey: "pinchDistance2") as? Double {
    engine.config.pinchOn = pinch
    engine.config.pinchOff = pinch + GestureConfig.releaseGap
}
reader.primary = [1: VNChirality.left, 2: .right][saved?.integer(forKey: "primaryHand") ?? 0] ?? .unknown

for (name, value) in overrides {
    let d = Double(value)
    switch name {
    case "pinchOn": engine.config.pinchOn = d!
    case "pinchOff": engine.config.pinchOff = d!
    case "dragSlop": engine.config.dragSlop = d!
    case "dragDelay": engine.config.dragDelay = d!
    case "dragNow": engine.config.dragNow = d!
    case "longPress": engine.config.longPress = d!
    case "shapeFrames": engine.config.shapeFrames = Int(d!)
    case "poseFrames": engine.config.poseFrames = Int(d!)
    case "releaseFrames": engine.config.releaseFrames = Int(d!)
    case "swipeSpeed": engine.config.swipeSpeed = d!
    case "swipeDistance": engine.config.swipeDistance = d!
    case "spreadThumb": engine.config.spreadThumb = d!
    case "spreadFingers": engine.config.spreadFingers = d!
    case "touchMargin": engine.config.touchMargin = d!
    case "approach": engine.config.approach = d!
    case "clickMin": engine.config.clickMin = d!
    case "driftTau": engine.config.driftTau = d!
    case "middleBias": engine.config.middleBias = d!
    case "middleOn": engine.config.middleOn = d!
    case "middleIndexStraight": engine.config.middleIndexStraight = d!
    case "middleRingOpen": engine.config.middleRingOpen = d!
    case "wakeHold": engine.config.wakeHold = d!
    case "shapeEdge": engine.config.shapeEdge = d!
    case "wakeStill": engine.config.wakeStill = d!
    case "closingIndex": engine.config.closingIndex = d!
    case "foldedRatio": engine.classifier.foldedRatio = d!
    case "foldedMean": engine.classifier.foldedMean = d!
    case "extendedRatio": engine.classifier.extendedRatio = d!
    case "curledRatio": engine.classifier.curledRatio = d!
    case "primary": reader.primary = ["left": .left, "right": .right][value] ?? .unknown
    default: print("Unknown setting: \(name)"); exit(2)
    }
}

// MARK: Labels

struct Segment { var label: String; var start: Double; var end: Double }
guard let data = try? Data(contentsOf: folder.appendingPathComponent("labels.json")),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let raw = json["segments"] as? [[String: Any]] else {
    print("No labels.json in \(folder.path)")
    exit(1)
}
let segments = raw.compactMap { s -> Segment? in
    guard let l = s["label"] as? String, let a = s["start"] as? Double, let b = s["end"] as? Double else { return nil }
    return Segment(label: l, start: a, end: b)
}
func segment(at t: Double) -> String { segments.first { t >= $0.start && t < $0.end }?.label ?? "gap" }

// MARK: Video

let asset = AVURLAsset(url: folder.appendingPathComponent("video.mov"))
let semaphore = DispatchSemaphore(value: 0)
var track: AVAssetTrack?
Task {
    track = try? await asset.loadTracks(withMediaType: .video).first
    semaphore.signal()
}
semaphore.wait()
guard let track, let assetReader = try? AVAssetReader(asset: asset) else {
    print("Cannot read video.mov")
    exit(1)
}
let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
])
assetReader.add(output)
assetReader.startReading()

// MARK: Run

var counts: [String: [String: Int]] = [:]
var frames: [String: (total: Int, seen: Int)] = [:]
var timeline: [(Double, String, String)] = []
var first: Double?
var lastMode = GestureMode.idle
// Edge data: palm positions as the person sees them (x mirrored), 0 to 1 in the camera frame.
var palms: [(t: Double, x: Double, y: Double)] = []
var losses: [(t: Double, x: Double, y: Double, gone: Double)] = []
var lostSince: (t: Double, x: Double, y: Double)?
var lastPalmSeen: (x: Double, y: Double)?

func wants(_ label: String, _ kind: String) -> Bool {
    if let k = label.split(separator: ":").first, let pk = PlaygroundTask.Kind(rawValue: String(k)) {
        return PlaygroundScript.rules(pk).atLeast[kind] != nil
    }
    guard let step = TestScript.steps.first(where: { $0.label == label }) else { return false }
    return (step.expect[kind] ?? 0) > 0 || step.atLeast[kind] != nil
}

/// The step an event belongs to, allowing for a late finish or an early start.
func owner(_ kind: String, _ t: Double) -> String {
    if let seg = segments.first(where: { t >= $0.start && t < $0.end }) {
        if t - seg.start < TestScript.carryover && !wants(seg.label, kind) { return "carryover" }
        return seg.label
    }
    if let next = segments.first(where: { $0.start > t && $0.start - t <= TestScript.anticipation }), wants(next.label, kind) {
        return next.label
    }
    return "gap"
}

func count(_ kind: String, _ t: Double) {
    let s = owner(kind, t)
    counts[s, default: [:]][kind, default: 0] += 1
    timeline.append((t, s, kind))
}

while let sample = output.copyNextSampleBuffer() {
    guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    if first == nil { first = pts }
    let t = pts - first!
    let reading = reader.read(pixels, time: t)
    let actions = engine.update(reading.frame, now: t)

    let s = segment(at: t)
    frames[s, default: (0, 0)].total += 1
    if reading.frame != nil { frames[s]!.seen += 1 }

    for a in actions {
        switch a {
        case .click: count("click", t)
        case .rightClick: count("rightClick", t)
        case .dismissMenu:
            // A long press that turned into a drag: its right-click was part of the drag.
            let seg = owner("rightClick", t)
            counts[seg, default: [:]]["rightClick", default: 1] -= 1
        case .press: count("drag", t)
        case .swipe: count("swipe", t)
        case .talkStart: count("talk", t)
        case .pause(let on): count(on ? "pause" : "resume", t)
        default: break
        }
    }
    if engine.mode == .grab && lastMode != .grab { count("grab", t) }
    if let p = reading.palm {
        let q = (x: 1 - Double(p.x), y: 1 - Double(p.y))   // mirrored, y down: as the person sees it
        palms.append((t, q.x, q.y))
        lastPalmSeen = q
        if let l = lostSince {
            losses.append((l.t, l.x, l.y, t - l.t))
            lostSince = nil
        }
    } else if let last = lastPalmSeen {
        lostSince = (t, last.x, last.y)
        lastPalmSeen = nil
    }
    if let dump {
        func f(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "" }
        let fr = engine.fingerRatios
        var scale: Double?
        if let fm = reading.frame, let w = fm.point(.wrist, minConfidence: 0.3), let m = fm.point(.middleMCP, minConfidence: 0.3) { scale = (m - w).length }
        let p = reading.palm
        let line = [String(format: "%.3f", t), s, "\(engine.mode)", "\(engine.rawPose)", f(engine.pinchRatio),
                    f(fr[0]), f(fr[1]), f(fr[2]), f(fr[3]), f(p.map { Double($0.x) * reading.aspect }), f(p.map { Double($0.y) }), f(scale), f(engine.middleRatio)]
        dump.write((line.joined(separator: ",") + "\n").data(using: .utf8)!)
    }
    if let (a, b) = trace, t >= a, t <= b {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "  - " }
        let fingers = engine.fingerRatios.map(f).joined(separator: " ")
        let names = actions.compactMap { a -> String? in
            switch a {
            case .move, .scroll: return nil
            default: return "\(a)"
            }
        }.joined(separator: ",")
        print(String(format: "%6.2f", t), "\(engine.mode)".padding(toLength: 6, withPad: " ", startingAt: 0),
              "raw:\(engine.rawPose)".padding(toLength: 9, withPad: " ", startingAt: 0),
              "pinch:\(f(engine.pinchRatio))", "held:\(f(engine.pinchHeld))", "fingers:\(fingers)",
              reading.frame == nil ? "NOHAND" : "", names)
    }
    lastMode = engine.mode
}

// MARK: Report

if verbose {
    for (t, s, k) in timeline { print(String(format: "%7.2fs  %-10@  %@", t, s, k)) }
    print("")
}

/// Where the hand works in the camera frame, and where it leaves it.
func edgeReport() {
    func pct(_ v: [Double], _ q: Double) -> Double { v.isEmpty ? 0 : v.sorted()[min(v.count - 1, Int(Double(v.count) * q))] }
    func edge(_ x: Double, _ y: Double) -> String {
        let d = [("left", x), ("right", 1 - x), ("top", y), ("bottom", 1 - y)].min { $0.1 < $1.1 }!
        return String(format: "%@ (%.2f from it)", d.0, d.1)
    }
    print("\nedges (camera frame as you see it: x 0 left to 1 right, y 0 top to 1 bottom)")
    let xs = palms.map(\.x), ys = palms.map(\.y)
    print(String(format: "  whole session, palm 5%%-95%%: x %.2f-%.2f, y %.2f-%.2f", pct(xs, 0.05), pct(xs, 0.95), pct(ys, 0.05), pct(ys, 0.95)))
    for seg in segments where seg.label.hasPrefix("reach:") || seg.label.hasPrefix("leave:") {
        let p = palms.filter { $0.t >= seg.start && $0.t < seg.end }
        let l = losses.filter { $0.t >= seg.start && $0.t < seg.end }
        guard !p.isEmpty else { print("  \(seg.label): no hand seen"); continue }
        var line = String(format: "  %@: palm x %.2f-%.2f, y %.2f-%.2f", seg.label,
                          p.map(\.x).min()!, p.map(\.x).max()!, p.map(\.y).min()!, p.map(\.y).max()!)
        let out = l.filter { $0.gone >= 0.5 }
        if !out.isEmpty { line += "; left view " + out.map { String(format: "at %.1fs by the ", $0.t) + edge($0.x, $0.y) }.joined(separator: ", ") }
        print(line)
    }
    // Brief dropouts: Vision missed a hand that was still there. Exits: the hand left for half a second or more.
    let brief = losses.filter { $0.gone < 0.5 }, exits = losses.filter { $0.gone >= 0.5 }
    func side(_ l: (t: Double, x: Double, y: Double, gone: Double)) -> (String, Double) {
        [("left", l.x), ("right", 1 - l.x), ("top", l.y), ("bottom", 1 - l.y)].min { $0.1 < $1.1 }!
    }
    var bySide: [String: [Double]] = [:]
    for l in brief { let s = side(l); bySide[s.0, default: []].append(s.1) }
    print("  brief dropouts (under 0.5 s): \(brief.count) in all; nearest edge: " + bySide.sorted { $0.value.count > $1.value.count }
        .map { String(format: "%@ %d (median %.2f from it)", $0.key, $0.value.count, pct($0.value, 0.5)) }.joined(separator: ", "))
    for l in exits {
        let s = side(l)
        print(String(format: "  out of view %.1fs at %.1fs, left by the %@ at %.2f from it", l.gone, l.t, s.0, s.1))
    }
}

if segments.allSatisfy({ $0.label == "use" }) {
    // Everyday use: no prompts to score. Print what Glide did and when.
    for (t, _, k) in timeline { print(String(format: "%7.2fs  %@", t, k)) }
    let f = frames["use"] ?? (0, 0)
    print("hand seen \(f.total > 0 ? f.seen * 100 / f.total : 0)% of \(f.total) frames")
    exit(0)
}

if segments.contains(where: { $0.label.contains(":") || $0.label == "free" }) {
    // Playground: each segment is a task whose intent is known. Score it by its rules.
    var problems = 0
    print("task                 hand   replay                         live")
    let live = (try? Data(contentsOf: folder.appendingPathComponent("events.json")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["events"] as? [[String: Any]] ?? []
    for seg in segments where seg.label != "free" {
        guard let kindName = seg.label.split(separator: ":").first,
              let kind = PlaygroundTask.Kind(rawValue: String(kindName)) else { continue }
        let got = counts[seg.label] ?? [:]
        let rules = PlaygroundScript.rules(kind)
        var issues: [String] = []
        for (k, n) in rules.atLeast where (got[k] ?? 0) < n { issues.append("\(k) \(got[k] ?? 0), want \(n)") }
        for k in rules.never where (got[k] ?? 0) > 0 { issues.append("\(k) \(got[k]!), want 0") }
        problems += issues.count
        // What the objects saw while this task ran.
        let during = live.filter { e in
            guard let t = e["t"] as? Double, e["source"] as? String == "playground" else { return false }
            return t >= seg.start && t < seg.end
        }
        let misses = during.filter { $0["event"] as? String == "miss" }.count
        let skipped = during.contains { $0["event"] as? String == "skip" }
        var liveNote = skipped ? "skipped" : "done"
        if misses > 0 { liveNote += ", \(misses) miss" }
        let f = frames[seg.label] ?? (0, 0)
        let seen = f.total > 0 ? f.seen * 100 / f.total : 0
        let name = seg.label.padding(toLength: 20, withPad: " ", startingAt: 0)
        let result = (issues.isEmpty ? "ok" : issues.joined(separator: "; ")).padding(toLength: 30, withPad: " ", startingAt: 0)
        print("\(name) \(String(format: "%3d%%", seen))   \(result) \(liveNote)")
    }
    if let free = counts["free"], !free.isEmpty {
        print("free play: " + free.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
    }
    edgeReport()
    let missTimes = live.filter { $0["event"] as? String == "miss" }.compactMap { $0["t"] as? Double }
    if !missTimes.isEmpty {
        print("live clicks on nothing at: " + missTimes.map { String(format: "%.1fs", $0) }.joined(separator: ", "))
    }
    print(problems == 0 ? "All tasks pass." : "\(problems) problems.")
    exit(problems == 0 ? 0 : 1)
}

var failures = 0
print("step         hand   result")
for step in TestScript.steps {
    let got = counts[step.label] ?? [:]
    var problems: [String] = []
    for kind in TestScript.kinds {
        let n = got[kind] ?? 0
        if let min = step.atLeast[kind] {
            if n < min { problems.append("\(kind) \(n), want at least \(min)") }
        } else {
            let want = step.expect[kind] ?? 0
            if n != want { problems.append("\(kind) \(n), want \(want)") }
        }
    }
    failures += problems.count
    let f = frames[step.label] ?? (0, 0)
    let seen = f.total > 0 ? Int(Double(f.seen) / Double(f.total) * 100) : 0
    let name = step.label.padding(toLength: 12, withPad: " ", startingAt: 0)
    print("\(name) \(String(format: "%3d%%", seen))   \(problems.isEmpty ? "ok" : problems.joined(separator: "; "))")
}
for (name, key) in [("between steps", "gap"), ("left over from the step before", "carryover")] {
    if let c = counts[key], !c.isEmpty {
        print("\(name): " + c.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", "))
    }
}
print(failures == 0 ? "All steps pass." : "\(failures) problems.")
exit(failures == 0 ? 0 : 1)
