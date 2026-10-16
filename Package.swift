// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcflow",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1")
    ],
    targets: [
        .executableTarget(
            name: "xcflow",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ]
        ),
        .testTarget(
            name: "xcflowTests",
            dependencies: ["xcflow"]
        )
    ]
)
