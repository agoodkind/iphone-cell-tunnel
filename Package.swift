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
        .executable(name: "celltunnelctl", targets: ["celltunnelctl"]),
        .executable(name: "celltunneld", targets: ["celltunneld"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.7.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
        .package(
            url: "https://github.com/agoodkind/wireguard-apple.git",
            revision: "097baca"
        ),
    ],
    targets: [
        .target(
            name: "CellTunnelCore",
            dependencies: [
                "CellTunnelLog",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ]
        ),
        .target(name: "CellTunnelLog"),
        .executableTarget(
            name: "celltunnelctl",
            dependencies: [
                "CellTunnelCore",
                "CellTunnelLog",
            ],
            path: "Tools/CellTunnelCtl"
        ),
        .executableTarget(
            name: "celltunneld",
            dependencies: [
                "CellTunnelCore",
                "CellTunnelLog",
                .product(name: "WireGuardKit", package: "wireguard-apple"),
            ],
            path: "Sources/CellTunnelDaemon"
        ),
        .testTarget(
            name: "CellTunnelCoreTests",
            dependencies: ["CellTunnelCore"]
        ),
    ]
)
