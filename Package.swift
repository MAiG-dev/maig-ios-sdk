// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIGatewaySDK",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "AIGatewaySDK",
            targets: ["AIGatewaySDK"]
        )
    ],
    targets: [
        .target(
            name: "AIGatewaySDK",
            path: "Sources/AIGatewaySDK"
        ),
        .testTarget(
            name: "AIGatewaySDKTests",
            dependencies: ["AIGatewaySDK"],
            path: "Tests/AIGatewaySDKTests"
        )
    ]
)
