// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ERPNextKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "ERPNextKit", targets: ["ERPNextKit"]),
        // The MCP server (docs/MCP.md): `swift build -c release --product tula-mcp`.
        .executable(name: "tula-mcp", targets: ["tula-mcp"]),
    ],
    targets: [
        .target(name: "ERPNextKit"),
        .testTarget(name: "ERPNextKitTests", dependencies: ["ERPNextKit"]),
        // The protocol and the tools, with no I/O of their own, so tests can
        // drive them against the demo data.
        .target(name: "TulaMCPCore", dependencies: ["ERPNextKit"]),
        .executableTarget(name: "tula-mcp", dependencies: ["TulaMCPCore", "ERPNextKit"]),
        .testTarget(name: "TulaMCPCoreTests", dependencies: ["TulaMCPCore", "ERPNextKit"]),
    ]
)
