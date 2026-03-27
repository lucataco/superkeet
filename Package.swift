// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Superkeet",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Superkeet", targets: ["Superkeet"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "Superkeet",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/Superkeet",
            resources: [
                .copy("../../Resources/Info.plist")
            ]
        ),
        .testTarget(
            name: "SuperkeetTests",
            dependencies: ["Superkeet"],
            path: "Tests/SuperkeetTests"
        )
    ]
)
