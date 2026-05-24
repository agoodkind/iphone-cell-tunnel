// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CellTunnelTools",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "CellTunnelDev", targets: ["CellTunnelDev"]),
        .executable(name: "LoggingAudit", targets: ["LoggingAudit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0")
    ],
    targets: [
        .executableTarget(
            name: "CellTunnelDev",
            path: "CellTunnelDev"
        ),
        .executableTarget(
            name: "LoggingAudit",
            dependencies: [
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
            ],
            path: "LoggingAudit"
        ),
    ]
)
