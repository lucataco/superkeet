// swift-tools-version: 6.0
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
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "Superkeet",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/Superkeet"
        ),
        .testTarget(
            name: "SuperkeetTests",
            dependencies: ["Superkeet"],
            path: "Tests/SuperkeetTests"
        )
    ],
    swiftLanguageModes: [.v6]
)
