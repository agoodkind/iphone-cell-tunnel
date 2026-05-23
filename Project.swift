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
        "CONFIGURATION_BUILD_DIR": "$(SRCROOT)/Products/$(CONFIGURATION)/$(PLATFORM_NAME)",
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

let project = Project(
    name: projectName,
    organizationName: organizationName,
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
                base: [
                    "PRODUCT_NAME": "CellTunnelPhone",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                ]
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
