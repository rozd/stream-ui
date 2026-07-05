// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "StreamUI",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "StreamUI",
            targets: ["StreamUI"]
        ),
    ],
    targets: [
        .target(
            name: "StreamUI"
        ),
        .testTarget(
            name: "StreamUITests",
            dependencies: ["StreamUI"]
        ),
    ]
)
