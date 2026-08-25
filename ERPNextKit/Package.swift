// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ERPNextKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "ERPNextKit", targets: ["ERPNextKit"])
    ],
    targets: [
        .target(name: "ERPNextKit"),
        .testTarget(name: "ERPNextKitTests", dependencies: ["ERPNextKit"]),
    ]
)
