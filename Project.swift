import Foundation
import ProjectDescription

let projectName = "CellTunnel"
let organizationName = "goodkind.io"
let iOSDeploymentTarget = DeploymentTargets.iOS("18.0")
let macOSDeploymentTarget = DeploymentTargets.macOS("15.0")

let debug = Configuration.debug(name: "Debug")
let release = Configuration.release(name: "Release")

let projectSettings = Settings.settings(
    base: [
        "SWIFT_VERSION": "6.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": "18.0",
        "MACOSX_DEPLOYMENT_TARGET": "15.0",
        "SYMROOT": "$(SRCROOT)/build",
        "OBJROOT": "$(SRCROOT)/build/Intermediates.noindex",
        "MARKETING_VERSION": "0.1.0",
        "CURRENT_PROJECT_VERSION": "1",
    ],
    configurations: [debug, release],
    defaultSettings: .recommended
)

let appDependencies: [TargetDependency] = [
    .target(name: "CellTunnelCore"),
    .target(name: "CellTunnelLog"),
]

let cellTunnelPhoneBaseSettings: SettingsDictionary = {
    var settings: SettingsDictionary = [
        "PRODUCT_NAME": "CellTunnelPhone",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
    ]
    let environment = ProcessInfo.processInfo.environment
    let team =
        (environment["TUIST_DEVELOPMENT_TEAM"] ?? environment["DEVELOPMENT_TEAM"] ?? "")
        .trimmingCharacters(in: .whitespaces)
    if !team.isEmpty {
        settings["DEVELOPMENT_TEAM"] = SettingValue(stringLiteral: team)
        settings["CODE_SIGN_STYLE"] = "Automatic"
    }
    return settings
}()

let project = Project(
    name: projectName,
    organizationName: organizationName,
    packages: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.4.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.7.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.4.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.38.0"),
    ],
    settings: projectSettings,
    targets: [
        .target(
            name: "CellTunnelCore",
            destinations: [.iPhone, .mac],
            product: .framework,
            bundleId: "io.goodkind.CellTunnelCore",
            infoPlist: .default,
            sources: [
                "Sources/CellTunnelCore/**"
            ],
            dependencies: [
                .target(name: "CellTunnelLog"),
                .external(name: "GRPCCore"),
                .external(name: "GRPCNIOTransportHTTP2"),
                .external(name: "GRPCProtobuf"),
                .external(name: "SwiftProtobuf"),
            ]
        ),
        .target(
            name: "CellTunnelLog",
            destinations: [.iPhone, .mac],
            product: .framework,
            bundleId: "io.goodkind.CellTunnelLog",
            infoPlist: .default,
            sources: [
                "Sources/CellTunnelLog/**"
            ]
        ),
        .target(
            name: "CellTunnelPhone",
            destinations: [.iPhone],
            product: .app,
            bundleId: "io.goodkind.CellTunnelPhone",
            deploymentTargets: iOSDeploymentTarget,
            infoPlist: .file(path: "Apps/iOS/Info.plist"),
            sources: [
                "Apps/iOS/**"
            ],
            dependencies: appDependencies,
            settings: .settings(
                base: cellTunnelPhoneBaseSettings
            )
        ),
        .target(
            name: "CellTunnelMac",
            destinations: [.mac],
            product: .app,
            bundleId: "io.goodkind.CellTunnelMac",
            deploymentTargets: macOSDeploymentTarget,
            infoPlist: .file(path: "Apps/macOS/Info.plist"),
            sources: [
                "Apps/macOS/**"
            ],
            dependencies: appDependencies,
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "CellTunnelMac",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                    "CODE_SIGN_ENTITLEMENTS": "Apps/macOS/Entitlements/CellTunnelMac.entitlements",
                ]
            )
        ),
    ],
    schemes: [
        .scheme(
            name: "CellTunnelPhone",
            shared: true,
            buildAction: .buildAction(targets: [.target("CellTunnelPhone")]),
            runAction: .runAction(configuration: "Debug"),
            archiveAction: .archiveAction(configuration: "Release"),
            profileAction: .profileAction(configuration: "Release"),
            analyzeAction: .analyzeAction(configuration: "Debug")
        ),
        .scheme(
            name: "CellTunnelMac",
            shared: true,
            buildAction: .buildAction(targets: [.target("CellTunnelMac")]),
            runAction: .runAction(configuration: "Debug"),
            archiveAction: .archiveAction(configuration: "Release"),
            profileAction: .profileAction(configuration: "Release"),
            analyzeAction: .analyzeAction(configuration: "Debug")
        ),
    ]
)
