// swift-tools-version: 6.0
import PackageDescription

#if TUIST
    import ProjectDescription

    let packageSettings = PackageSettings(
        productTypes: [
            "WireGuardKit": .framework
        ],
        targetSettings: [
            "WireGuardKit": [
                "LIBRARY_SEARCH_PATHS": ["/Users/agoodkind/Sites/iphone-cell-tunnel/.build/vendor"]
            ],
            "WireGuardKitGo": [
                "LIBRARY_SEARCH_PATHS": ["/Users/agoodkind/Sites/iphone-cell-tunnel/.build/vendor"]
            ],
        ]
    )
#endif

let package = Package(
    name: "CellTunnelTuistDependencies",
    dependencies: [
        .package(url: "https://github.com/agoodkind/wireguard-apple.git", branch: "master")
    ]
)
