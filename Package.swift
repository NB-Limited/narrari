// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error), .enableUpcomingFeature("ExistentialAny")]

let package = Package(
    name: "NarrariKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NarrariKit", targets: ["NarrariKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.4.0"),
        .package(url: "https://github.com/huggingface/swift-huggingface", exact: "1.0.1"),
    ],
    targets: [
        .target(
            name: "NarrariKit",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            resources: [.copy("Resources/Sounds"), .copy("Resources/SummaryTemplates")],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "narrari-dev",
            dependencies: [
                "NarrariKit",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "scripts/dev",
            swiftSettings: strict
        ),
        .testTarget(
            name: "NarrariKitTests",
            dependencies: ["NarrariKit"],
            path: "tests",
            swiftSettings: strict
        ),
    ]
)
