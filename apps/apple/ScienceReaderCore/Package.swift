// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScienceReaderCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ScienceReaderCore", targets: ["ScienceReaderCore"]),
               .executable(name: "ScienceReaderWireCheck", targets: ["ScienceReaderWireCheck"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ScienceReaderCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ScienceReaderWireCheck", dependencies: ["ScienceReaderCore"], path: "Tests/WireCheck"),
        .testTarget(name: "ScienceReaderCoreTests", dependencies: ["ScienceReaderCore", "CSQLite"], resources: [.process("Fixtures")])
    ]
)
