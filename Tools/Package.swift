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
        .package(path: ".."),
        .package(path: "../../swift-makefile"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "603.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CellTunnelDev",
            dependencies: [
                .product(name: "CellTunnelCore", package: "iphone-cell-tunnel"),
                .product(name: "CellTunnelLog", package: "iphone-cell-tunnel"),
                .product(name: "SwiftMkCore", package: "swift-makefile"),
            ],
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
