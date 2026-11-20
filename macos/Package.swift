// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Huecast",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Huecast", targets: ["Huecast"]),
    ],
    targets: [
        // The sky engine: palette, conditions, forecast. No UI, so it also
        // builds and tests on Linux
        .target(name: "HuecastCore"),
        // The macOS app (SwiftUI + AppKit)
        .executableTarget(name: "Huecast", dependencies: ["HuecastCore"]),
        .testTarget(name: "HuecastCoreTests", dependencies: ["HuecastCore"]),
    ]
)
