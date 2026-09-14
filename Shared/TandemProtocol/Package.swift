// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TandemProtocol",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "TandemProtocol", targets: ["TandemProtocol"]),
    ],
    targets: [
        .target(name: "TandemProtocol", path: "Sources/TandemProtocol"),
        .testTarget(name: "TandemProtocolTests", dependencies: ["TandemProtocol"], path: "Tests/TandemProtocolTests"),
    ]
)
