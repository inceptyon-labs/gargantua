// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Gargantua",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GargantuaCore", targets: ["GargantuaCore"]),
        .executable(name: "Gargantua", targets: ["Gargantua"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Gargantua",
            dependencies: ["GargantuaCore"],
            path: "Sources/Gargantua"
        ),
        .target(
            name: "GargantuaCore",
            dependencies: ["Yams"],
            path: "Sources/GargantuaCore",
            resources: [.copy("Resources/cleanup_rules")]
        ),
        .testTarget(
            name: "GargantuaCoreTests",
            dependencies: ["GargantuaCore"],
            path: "Tests/GargantuaCoreTests"
        )
    ]
)
