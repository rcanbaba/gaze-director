// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GazeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GazeCore", targets: ["GazeCore"]),
    ],
    targets: [
        .target(name: "GazeCore"),
        .testTarget(name: "GazeCoreTests", dependencies: ["GazeCore"]),
    ]
)
