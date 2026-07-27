// swift-tools-version: 6.0

import Foundation
import PackageDescription

let schedulerInfoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/GargantuaScheduler/Info.plist")
    .path

// GARGANTUA_LICENSING=1 in the environment turns on the commercial-licensing
// build path (trial clock, license gate enforcement, FastSpring activation).
// Off by default — `swift build` from a fresh clone produces a fully unlocked
// AGPL binary. Release CI sets the env var; see Scripts/release/build.sh.
let licensingEnabled = Context.environment["GARGANTUA_LICENSING"] == "1"
let licensingSwiftSettings: [SwiftSetting] = licensingEnabled
    ? [.define("GARGANTUA_LICENSING")]
    : []

// Swift 6 language mode is enabled per-target: SwiftPM has no package-wide
// swiftSettings hook, so every Swift target appends this array.
let swift6SwiftSettings: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "Gargantua",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GargantuaCore", targets: ["GargantuaCore"]),
        .library(name: "GargantuaLicensing", targets: ["GargantuaLicensing"]),
        .executable(name: "Gargantua", targets: ["Gargantua"]),
        .executable(name: "GargantuaScheduler", targets: ["GargantuaScheduler"]),
        .executable(name: "GargantuaMCP", targets: ["GargantuaMCP"]),
        .executable(name: "GargantuaPrivilegedHelper", targets: ["GargantuaPrivilegedHelper"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "Gargantua",
            dependencies: [
                "GargantuaCore",
                "GargantuaAppKitShims",
                "GargantuaLicensing",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Gargantua",
            plugins: [
                "BuildMetallibPlugin"
            ]
        ),
        .target(
            name: "GargantuaAppKitShims",
            path: "Sources/GargantuaAppKitShims",
            publicHeadersPath: "include"
        ),
        .plugin(
            name: "BuildMetallibPlugin",
            capability: .buildTool(),
            path: "Plugins/BuildMetallibPlugin"
        ),
        .executableTarget(
            name: "GargantuaMCP",
            dependencies: ["GargantuaCore", "GargantuaLicensing"],
            path: "Sources/GargantuaMCP"
        ),
        .executableTarget(
            name: "GargantuaScheduler",
            dependencies: ["GargantuaCore"],
            path: "Sources/GargantuaScheduler",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker",
                    "-sectcreate",
                    "-Xlinker",
                    "__TEXT",
                    "-Xlinker",
                    "__info_plist",
                    "-Xlinker",
                    schedulerInfoPlistPath
                ])
            ]
        ),
        .executableTarget(
            name: "GargantuaPrivilegedHelper",
            dependencies: ["GargantuaCore"],
            path: "Sources/GargantuaPrivilegedHelper"
        ),
        .target(
            name: "GargantuaCore",
            dependencies: [
                "GargantuaLicensing",
                "Yams",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Sources/GargantuaCore",
            resources: [
                .copy("Resources/cleanup_rules"),
                .copy("Resources/command_rules"),
                .copy("Resources/uninstall_rules"),
                .copy("Resources/safety_policy"),
                .copy("Resources/Brand"),
                .copy("Resources/bin"),
                .copy("Resources/rules-sync.json")
            ],
            swiftSettings: swift6SwiftSettings
        ),
        .target(
            name: "GargantuaLicensing",
            path: "Sources/GargantuaLicensing",
            swiftSettings: licensingSwiftSettings
        ),
        .testTarget(
            name: "GargantuaCoreTests",
            dependencies: [
                "GargantuaCore",
                "GargantuaLicensing",
                .product(name: "Tokenizers", package: "swift-transformers")
            ],
            path: "Tests/GargantuaCoreTests",
            swiftSettings: swift6SwiftSettings
        ),
        .testTarget(
            name: "GargantuaLicensingTests",
            dependencies: ["GargantuaLicensing"],
            path: "Tests/GargantuaLicensingTests",
            swiftSettings: licensingSwiftSettings
        )
    ]
)
