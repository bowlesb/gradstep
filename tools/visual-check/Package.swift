// swift-tools-version: 6.0
// Before/after screenshot comparison and contact sheets for visual checks
// (docs/VISUAL_CHECK.md). CoreGraphics and ImageIO only.
import PackageDescription

let package = Package(
    name: "visual-check",
    platforms: [.macOS("26.0")],
    targets: [.executableTarget(name: "visual-check", path: "Sources", swiftSettings: [.swiftLanguageMode(.v5)])]
)
