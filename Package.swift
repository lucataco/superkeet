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
                // Only used by `swift run` to read CFBundleVersion etc.
                // install.sh and package_release.sh copy Info.plist into the
                // .app bundle Contents/ directory separately.
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
