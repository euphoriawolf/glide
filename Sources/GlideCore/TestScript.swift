import Foundation

/// The guided test session: prompts the person follows, and what Glide must detect in each.
/// The app records a session with these labels; GlideReplay scores it.
public struct TestStep {
    public var label: String
    public var prompt: String
    public var seconds: Double
    /// Action counts that must match. A missing key means 0 is expected, except where `atLeast` names it.
    public var expect: [String: Int]
    /// Action counts that must reach at least this value. Other counts are not checked for these keys.
    public var atLeast: [String: Int]

    public init(_ label: String, _ prompt: String, _ seconds: Double, expect: [String: Int] = [:], atLeast: [String: Int] = [:]) {
        self.label = label
        self.prompt = prompt
        self.seconds = seconds
        self.expect = expect
        self.atLeast = atLeast
    }
}

public enum TestScript {
    /// Kinds of action GlideReplay counts.
    public static let kinds = ["click", "rightClick", "drag", "grab", "swipe", "talk"]

    public static let steps: [TestStep] = [
        TestStep("move", "Move the pointer around. Do not click.", 10),
        TestStep("click", "Click 5 times, slowly.", 12, atLeast: ["click": 5]),
        TestStep("rightClick", "Right-click 3 times: pinch and hold until the ring fills.", 12, atLeast: ["rightClick": 3]),
        TestStep("drag", "Drag 3 times: pinch, move, open.", 12, atLeast: ["drag": 3]),
        TestStep("scroll", "Close your hand and scroll up and down.", 10, atLeast: ["grab": 1]),
        TestStep("swipe", "Spread your hand and swipe left, then right.", 10, atLeast: ["swipe": 2]),
        TestStep("talk", "Two fingers up for 2 seconds, then lower. Do it twice.", 10, atLeast: ["talk": 2]),
        TestStep("rest", "Rest your hand in view. Do nothing.", 8),
    ]

    /// Seconds between steps, not scored.
    public static let gap = 2.0
    /// An unexpected event this early in a step is left over from the step before.
    public static let carryover = 1.0
    /// An expected event this close before a step belongs to it: the person started early.
    public static let anticipation = 0.6
}

/// A task in the playground. Its label in a recording is "kind:id", so GlideReplay knows the intent.
public struct PlaygroundTask {
    public enum Kind: String, CaseIterable {
        case click, rightClick, drag, type, scroll, swipe
        /// Move the pointer to a screen corner. Shows whether reaching the screen pushes the hand out of view.
        case reach
        /// Take the hand out of view and bring it back. Shows where tracking ends and how it recovers.
        case leave
    }
    public var id: String
    public var kind: Kind
    public var prompt: String
    public var label: String { "\(kind.rawValue):\(id)" }

    public init(_ kind: Kind, _ id: String, _ prompt: String) {
        self.kind = kind
        self.id = id
        self.prompt = prompt
    }
}

public enum PlaygroundScript {
    public static let tasks: [PlaygroundTask] = [
        PlaygroundTask(.click, "large", "Click the large circle"),
        PlaygroundTask(.click, "medium", "Click the medium circle"),
        PlaygroundTask(.click, "small", "Click the small circle"),
        PlaygroundTask(.click, "button", "Click Save"),
        PlaygroundTask(.rightClick, "notes", "Right-click Notes: pinch and hold, then choose Rename"),
        PlaygroundTask(.drag, "photos", "Drag Photos into Archive"),
        PlaygroundTask(.drag, "projects", "Drag Projects into Archive"),
        PlaygroundTask(.type, "field", "Click the text field, then dictate a sentence"),
        PlaygroundTask(.scroll, "list", "Scroll the list to row 40"),
        PlaygroundTask(.swipe, "next", "Swipe left to desktop 2"),
        PlaygroundTask(.swipe, "back", "Swipe right, back to desktop 1"),
        PlaygroundTask(.reach, "tl", "Move the pointer to the top-left corner of the screen"),
        PlaygroundTask(.reach, "tr", "Now the top-right corner"),
        PlaygroundTask(.reach, "br", "Now the bottom-right corner"),
        PlaygroundTask(.reach, "bl", "Now the bottom-left corner"),
        PlaygroundTask(.leave, "side", "Move your hand out of view to the side, then back"),
        PlaygroundTask(.leave, "down", "Lower your hand out of view, then raise it"),
    ]

    /// What GlideReplay checks for a task: kinds that must happen at least once, and kinds that must not happen.
    /// Kinds in neither list are allowed: picking a menu item needs a click, for example.
    public static func rules(_ kind: PlaygroundTask.Kind) -> (atLeast: [String: Int], never: [String]) {
        switch kind {
        case .click: (["click": 1], ["rightClick", "swipe", "grab"])
        case .rightClick: (["rightClick": 1], ["swipe", "grab"])
        case .drag: (["drag": 1], ["rightClick", "swipe", "grab"])
        case .type: (["talk": 1], ["rightClick", "swipe", "grab"])
        case .scroll: (["grab": 1], ["click", "rightClick", "drag", "swipe"])
        case .swipe: (["swipe": 1], ["click", "rightClick", "drag", "grab"])
        case .reach, .leave: ([:], ["click", "rightClick", "drag", "swipe", "grab"])
        }
    }
}
