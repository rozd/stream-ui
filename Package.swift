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
            name: "StreamUI",
            exclude: ["Skip"]
        ),
        .testTarget(
            name: "StreamUITests",
            dependencies: ["StreamUI"],
            exclude: ["Skip"]
        ),
    ]
)

// Skip (https://skip.dev) Android support. Active only under Skip's tooling —
// `skip android build/test` and Skip Fuse app builds set SKIP_BRIDGE=1 — so
// plain Apple consumers resolve a dependency-free package. StreamUI is a
// native-mode Skip module (Sources/StreamUI/Skip/skip.yml): the same Swift is
// compiled by the Android toolchain, with `import SwiftUI` satisfied by
// SkipFuseUI's SwiftUI shim over Jetpack Compose and `import Observation` by
// the Swift stdlib.
if Context.environment["SKIP_BRIDGE"] ?? "0" != "0" {
    package.dependencies += [
        .package(url: "https://source.skip.tools/skip.git", from: "1.9.4"),
        .package(url: "https://source.skip.tools/skip-fuse-ui.git", from: "1.0.0"),
    ]
    package.targets.forEach { target in
        target.dependencies += [.product(name: "SkipFuseUI", package: "skip-fuse-ui")]
        target.plugins = (target.plugins ?? []) + [.plugin(name: "skipstone", package: "skip")]
    }
    // Bridged libraries must be dynamic so their symbols reach the JNI layer.
    package.products = package.products.map { product in
        guard let library = product as? Product.Library else { return product }
        return .library(name: library.name, type: .dynamic, targets: library.targets)
    }
}
