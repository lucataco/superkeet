// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Superkeet",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Superkeet",
            path: "Sources/Superkeet",
            resources: [
                .copy("../../Resources/Info.plist")
            ]
        )
    ]
)
