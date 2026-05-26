// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CellTunnelTuistDependencies",
    dependencies: [
        .package(
            url: "https://github.com/agoodkind/wireguard-apple.git",
            revision: "097baca"
        )
    ]
)
