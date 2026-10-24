// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScienceReaderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ScienceReaderCore", targets: ["ScienceReaderCore"]),
               .executable(name: "ScienceReaderWireCheck", targets: ["ScienceReaderWireCheck"]),
               .executable(name: "DevicePDFRouteTool", targets: ["DevicePDFRouteTool"]),
               .executable(name: "FullTextBenchTool", targets: ["FullTextBenchTool"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ScienceReaderCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ScienceReaderWireCheck", dependencies: ["ScienceReaderCore"], path: "Tests/WireCheck"),
        // The on-device PDF route on a Mac, for fixture conformance and timings (docs/architecture/DEVICE_PDF_ROUTE.md).
        .executableTarget(name: "DevicePDFRouteTool", dependencies: ["ScienceReaderCore"], path: "Tools/DevicePDFRouteTool"),
        // The full-text index's size, load time and query latency on a synthetic library (NATIVE_LIBRARY_SEARCH.md).
        .executableTarget(name: "FullTextBenchTool", dependencies: ["ScienceReaderCore"], path: "Tools/FullTextBenchTool"),
        .testTarget(name: "ScienceReaderCoreTests", dependencies: ["ScienceReaderCore", "CSQLite"], resources: [.process("Fixtures")])
    ]
)
