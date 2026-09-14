// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TerasProtocol",
    platforms: [.macOS(.v14), .iOS(.v16)],
    products: [
        .library(name: "TerasProtocol", targets: ["TerasProtocol"]),
    ],
    targets: [
        .target(name: "TerasProtocol", path: "Sources/TerasProtocol"),
        .testTarget(name: "TerasProtocolTests", dependencies: ["TerasProtocol"], path: "Tests/TerasProtocolTests"),
    ]
)
