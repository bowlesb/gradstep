// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScienceReaderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ScienceReaderCore", targets: ["ScienceReaderCore"]),
               .executable(name: "ScienceReaderWireCheck", targets: ["ScienceReaderWireCheck"]),
               .executable(name: "DevicePDFRouteTool", targets: ["DevicePDFRouteTool"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ScienceReaderCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ScienceReaderWireCheck", dependencies: ["ScienceReaderCore"], path: "Tests/WireCheck"),
        // The on-device PDF route on a Mac, for fixture conformance and timings (docs/architecture/DEVICE_PDF_ROUTE.md).
        .executableTarget(name: "DevicePDFRouteTool", dependencies: ["ScienceReaderCore"], path: "Tools/DevicePDFRouteTool"),
        .testTarget(name: "ScienceReaderCoreTests", dependencies: ["ScienceReaderCore", "CSQLite"], resources: [.process("Fixtures")])
    ]
)
