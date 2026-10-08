// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Distilar",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "Distilar", targets: ["Distilar"]),
    ],
    targets: [
        .target(
            name: "Distilar",
            resources: [.process("Resources")],
            // Stated rather than implied: code runs where its own declaration
            // says, as in the apps that embed it, not on the main actor by default.
            swiftSettings: [.defaultIsolation(nil)]
        ),
        .testTarget(
            name: "DistilarTests",
            dependencies: ["Distilar"],
            swiftSettings: [.defaultIsolation(nil)]
        ),
    ]
)
