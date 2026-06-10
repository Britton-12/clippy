// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clippy",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Clippy",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            // AppKit delegates and Carbon callbacks are simpler under the v5
            // concurrency model; revisit when the whole app moves to Swift 6 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ClippyTests",
            dependencies: [
                "Clippy",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
