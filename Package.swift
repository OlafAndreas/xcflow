// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "xcflow",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
        .package(url: "https://github.com/OlafAndreas/swift-mediator.git", from: "0.1.2"),
        // Spike: match the toolchain's swift-syntax (6.3) to see whether SwiftPM uses a prebuilt on Linux.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "603.0.0"..<"604.0.0")
    ],
    targets: [
        .executableTarget(
            name: "xcflow",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "SwiftMediator", package: "swift-mediator"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ]
        ),
        .testTarget(
            name: "xcflowTests",
            dependencies: [
                "xcflow",
                .product(name: "SwiftMediatorTesting", package: "swift-mediator"),
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ]
        )
    ]
)
