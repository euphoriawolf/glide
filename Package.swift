// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Glide",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "GlideCore"),
        // Vision: camera frame to one primary hand. Shared by the app and GlideReplay.
        .target(name: "GlideVision", dependencies: ["GlideCore"]),
        .executableTarget(name: "Glide", dependencies: ["GlideCore", "GlideVision"]),
        // Runs a recorded test session through Vision and the gesture engine, and scores it.
        // Run: swift run GlideReplay <session folder> [--name value ...]
        .executableTarget(name: "GlideReplay", dependencies: ["GlideCore", "GlideVision"]),
        // Checks for GlideCore. Run: swift run GlideChecks
        .executableTarget(name: "GlideChecks", dependencies: ["GlideCore"]),
    ],
    swiftLanguageModes: [.v5]
)
