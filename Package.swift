// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Gargantua",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GargantuaCore", targets: ["GargantuaCore"]),
        .executable(name: "Gargantua", targets: ["Gargantua"]),
        .executable(name: "GargantuaMCP", targets: ["GargantuaMCP"]),
        .executable(name: "GargantuaPrivilegedHelper", targets: ["GargantuaPrivilegedHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "Gargantua",
            dependencies: ["GargantuaCore"],
            path: "Sources/Gargantua"
        ),
        .executableTarget(
            name: "GargantuaMCP",
            dependencies: ["GargantuaCore"],
            path: "Sources/GargantuaMCP"
        ),
        .executableTarget(
            name: "GargantuaPrivilegedHelper",
            dependencies: ["GargantuaCore"],
            path: "Sources/GargantuaPrivilegedHelper"
        ),
        .target(
            name: "GargantuaCore",
            dependencies: [
                "Yams",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/GargantuaCore",
            resources: [
                .copy("Resources/cleanup_rules"),
                .copy("Resources/uninstall_rules"),
                .copy("Resources/Brand"),
                .copy("Resources/bin")
            ]
        ),
        .testTarget(
            name: "GargantuaCoreTests",
            dependencies: [
                "GargantuaCore",
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Tests/GargantuaCoreTests"
        )
    ]
)
