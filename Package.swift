// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "Gargantua",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "GargantuaCore", targets: ["GargantuaCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "GargantuaCore",
            dependencies: ["Yams"],
            path: "Sources/GargantuaCore"
        ),
        .testTarget(
            name: "GargantuaCoreTests",
            dependencies: ["GargantuaCore"],
            path: "Tests/GargantuaCoreTests"
        )
    ]
)
