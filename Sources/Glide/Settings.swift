import AppKit
import GlideCore
import SwiftUI

/// User settings, stored in UserDefaults. Modeled on System Settings > Mouse.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard
    /// Called after any change, on the main thread.
    var onChange: () -> Void = {}

    enum DictationKey: String, CaseIterable, Identifiable {
        case fn, rightOption
        var id: String { rawValue }
        var title: String { self == .fn ? "fn" : "Right ⌥ Option" }
        var keyCode: UInt16 { self == .fn ? 63 : 61 }
    }

    @Published var trackingSpeed: Double { didSet { save("trackingSpeed", trackingSpeed) } }
    @Published var scrollSpeed: Double { didSet { save("scrollSpeed", scrollSpeed) } }
    @Published var naturalScrolling: Bool { didSet { save("naturalScrolling", naturalScrolling) } }
    /// Fingertip distance that counts as a pinch, as a ratio of hand size.
    @Published var pinchDistance: Double { didSet { save("pinchDistance2", pinchDistance) } }
    @Published var dictationKey: DictationKey { didSet { save("dictationKey", dictationKey.rawValue) } }
    @Published var primaryHand: PrimaryHand { didSet { save("primaryHand", primaryHand.rawValue) } }
    @Published var lowLightBoost: Bool { didSet { save("lowLightBoost", lowLightBoost) } }
    @Published var showPreview: Bool { didSet { save("showPreview", showPreview) } }
    @Published var onboarded: Bool { didSet { save("onboarded2", onboarded) } }
    /// Clean up dictated text with the on-device Apple Intelligence model.
    @Published var cleanUp: Bool { didSet { save("cleanUp", cleanUp) } }
    /// Names and terms the speech model should expect, separated by commas.
    @Published var vocabulary: String { didSet { save("vocabulary", vocabulary) } }

    private init() {
        trackingSpeed = d.object(forKey: "trackingSpeed") as? Double ?? 1.0
        scrollSpeed = d.object(forKey: "scrollSpeed") as? Double ?? 1.0
        naturalScrolling = d.object(forKey: "naturalScrolling") as? Bool ?? true
        pinchDistance = d.object(forKey: "pinchDistance2") as? Double ?? GestureConfig().pinchOn
        dictationKey = DictationKey(rawValue: d.string(forKey: "dictationKey") ?? "") ?? .fn
        primaryHand = PrimaryHand(rawValue: d.integer(forKey: "primaryHand")) ?? .either
        lowLightBoost = d.object(forKey: "lowLightBoost") as? Bool ?? true
        showPreview = d.bool(forKey: "showPreview")
        // A new key: the setup flow changed, so everyone sees it once more.
        onboarded = d.bool(forKey: "onboarded2")
        cleanUp = d.object(forKey: "cleanUp") as? Bool ?? true
        vocabulary = d.string(forKey: "vocabulary") ?? "Glide"
    }

    private func save(_ key: String, _ value: Any) {
        d.set(value, forKey: key)
        onChange()
    }
}

// MARK: - Window

final class SettingsWindow: NSWindow {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Glide Settings"
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: SettingsView(settings: .shared))
        center()
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings

    var body: some View {
        Form {
            Section("Pointer") {
                LabeledContent("Tracking speed") {
                    Slider(value: $settings.trackingSpeed, in: 0.4...2.0) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Slow")
                    } maximumValueLabel: {
                        Text("Fast")
                    }
                }
                LabeledContent("Pinch distance") {
                    Slider(value: $settings.pinchDistance, in: 0.08...0.24) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Touch")
                    } maximumValueLabel: {
                        Text("Close")
                    }
                }
            }
            Section("Scrolling") {
                LabeledContent("Scroll speed") {
                    Slider(value: $settings.scrollSpeed, in: 0.3...2.5) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Slow")
                    } maximumValueLabel: {
                        Text("Fast")
                    }
                }
                Toggle("Natural scrolling", isOn: $settings.naturalScrolling)
            }
            Section("Hand") {
                Picker("Primary hand", selection: $settings.primaryHand) {
                    Text("Right").tag(PrimaryHand.right)
                    Text("Left").tag(PrimaryHand.left)
                    Text("Either").tag(PrimaryHand.either)
                }
                Toggle("Low-light boost", isOn: $settings.lowLightBoost)
            }
            Section("Dictation") {
                Picker("Hold to talk", selection: $settings.dictationKey) {
                    ForEach(Settings.DictationKey.allCases) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $settings.cleanUp) {
                    Text("Clean up with Apple Intelligence")
                    if !DictationText.cleanUpAvailable {
                        Text("Turn on Apple Intelligence in System Settings to use this.")
                    }
                }
                .disabled(!DictationText.cleanUpAvailable)
                TextField("Words to know", text: $settings.vocabulary, prompt: Text("Names, products, terms"), axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
    }
}
