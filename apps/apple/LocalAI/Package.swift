// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalAI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LocalAI", targets: ["LocalAI"]),
               .executable(name: "LocalAIProbe", targets: ["LocalAIProbe"])],
    dependencies: [
        .package(path: "../ScienceReaderCore"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0")
    ],
    targets: [
        .target(name: "LocalAI", dependencies: ["ScienceReaderCore",
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "MLXVLM", package: "mlx-swift-lm"),
            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers")], resources: [.process("Resources")]),
        .executableTarget(name: "LocalAIProbe", dependencies: ["LocalAI", "ScienceReaderCore"]),
        .testTarget(name: "LocalAITests", dependencies: ["LocalAI"])
    ]
)
