// swift-tools-version: 6.0
// Mac-side review of recorded test sessions (docs/SESSION_REVIEW.md). Apple
// frameworks only: AVFoundation (frames, audio), Vision (on-screen text),
// Speech (on-device transcription of narration).
import PackageDescription

let package = Package(
    name: "session-review",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "session-review", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
