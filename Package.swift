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
    targets: [
        .target(
            name: "GargantuaCore",
            path: "Sources/GargantuaCore"
        ),
        .testTarget(
            name: "GargantuaCoreTests",
            dependencies: ["GargantuaCore"],
            path: "Tests/GargantuaCoreTests"
        )
    ]
)
