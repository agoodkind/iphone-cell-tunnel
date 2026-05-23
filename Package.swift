// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CellTunnel",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "CellTunnelCore", targets: ["CellTunnelCore"]),
        .library(name: "CellTunnelLog", targets: ["CellTunnelLog"]),
        .executable(name: "LoggingAudit", targets: ["LoggingAudit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0")
    ],
    targets: [
        .target(name: "CellTunnelCore"),
        .target(name: "CellTunnelLog"),
        .executableTarget(
            name: "LoggingAudit",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            path: "Tools/LoggingAudit"
        ),
        .testTarget(
            name: "CellTunnelCoreTests",
            dependencies: ["CellTunnelCore"]
        ),
    ]
)
