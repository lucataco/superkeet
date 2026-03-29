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
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Superkeet",
            dependencies: [],
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
