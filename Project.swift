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
        "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
    ],
    configurations: [debug, release],
    defaultSettings: .recommended
)

// Xcode "Update to recommended settings" pairs the module verifier toggle with
// these supported-language settings; making them explicit clears the warning on
// the C/Objective-C-capable framework targets.
let moduleVerifierSettings: SettingsDictionary = [
    "ENABLE_MODULE_VERIFIER": "YES",
    "MODULE_VERIFIER_SUPPORTED_LANGUAGES": "objective-c objective-c++",
    "MODULE_VERIFIER_SUPPORTED_LANGUAGE_STANDARDS": "gnu11 gnu++14",
]

// Recommended hardening settings Xcode flags on the macOS executable and
// app-extension targets.
let macHardenedRuntimeSettings: SettingsDictionary = [
    "ENABLE_HARDENED_RUNTIME": "YES",
    "REGISTER_APP_GROUPS": "YES",
]

let appDependencies: [TargetDependency] = [
    .target(name: "CellTunnelCore"),
    .target(name: "CellTunnelLog"),
]

let tunnelProviderDependencies: [TargetDependency] =
    appDependencies + [.external(name: "WireGuardKit")]

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

let agentLaunchAgentPlistGeneratorScript = TargetScript.pre(
    script: #"""
        swift "${SRCROOT}/Scripts/GenerateAgentLaunchAgentPlist.swift" \
            "${SRCROOT}/Templates/Plists/agent-launchd.plist.template" \
            "${SRCROOT}/Derived/Generated/${TARGET_NAME}/io.goodkind.celltunnel-agent.plist"
        """#,
    name: "Generate Agent LaunchAgent Plist",
    inputPaths: [
        "$(SRCROOT)/Templates/Plists/agent-launchd.plist.template",
        "$(SRCROOT)/Scripts/GenerateAgentLaunchAgentPlist.swift",
    ],
    outputPaths: [
        "$(SRCROOT)/Derived/Generated/$(TARGET_NAME)/io.goodkind.celltunnel-agent.plist"
    ]
)

let cellTunnelMacAutomaticSigningSettings: SettingsDictionary = {
    var settings: SettingsDictionary = [
        "CODE_SIGN_IDENTITY": "Apple Development"
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
    packages: [],
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
            dependencies: [.target(name: "CellTunnelLog")],
            settings: .settings(base: moduleVerifierSettings)
        ),
        .target(
            name: "CellTunnelLog",
            destinations: [.iPhone, .mac],
            product: .framework,
            bundleId: "io.goodkind.CellTunnelLog",
            infoPlist: .default,
            sources: [
                "Sources/CellTunnelLog/**"
            ],
            settings: .settings(base: moduleVerifierSettings)
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
            name: "CellTunnelAgent",
            destinations: [.mac],
            product: .app,
            bundleId: "io.goodkind.CellTunnel.Agent",
            deploymentTargets: macOSDeploymentTarget,
            infoPlist: .file(path: "Apps/macOS/Agent/Info.plist"),
            sources: [
                "Apps/macOS/Agent/**"
            ],
            copyFiles: [
                .wrapper(
                    name: "LaunchAgents",
                    subpath: "Contents/Library/LaunchAgents",
                    files: [
                        .glob(
                            pattern:
                                "Derived/Generated/CellTunnelAgent/io.goodkind.celltunnel-agent.plist"
                        )
                    ]
                )
            ],
            entitlements: .file(path: "Apps/macOS/Entitlements/Agent.entitlements"),
            scripts: [
                agentLaunchAgentPlistGeneratorScript
            ],
            dependencies: appDependencies + [.target(name: "CellTunnelTunnelProvider")],
            settings: .settings(
                base:
                    cellTunnelMacAutomaticSigningSettings
                    .merging(macHardenedRuntimeSettings) { _, hardened in hardened }
            )
        ),
        .target(
            name: "CellTunnelTunnelProvider",
            destinations: [.mac],
            product: .appExtension,
            bundleId: "io.goodkind.CellTunnel.Agent.TunnelProvider",
            deploymentTargets: macOSDeploymentTarget,
            infoPlist: .file(path: "Apps/macOS/TunnelProvider/Info.plist"),
            sources: [
                "Apps/macOS/TunnelProvider/**"
            ],
            entitlements: .file(path: "Apps/macOS/Entitlements/TunnelProvider.entitlements"),
            dependencies: tunnelProviderDependencies,
            settings: .settings(
                base:
                    cellTunnelMacAutomaticSigningSettings
                    .merging(macHardenedRuntimeSettings) { _, hardened in hardened }
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
            name: "CellTunnelAgent",
            shared: true,
            buildAction: .buildAction(targets: [.target("CellTunnelAgent")]),
            runAction: .runAction(configuration: "Debug"),
            archiveAction: .archiveAction(configuration: "Release"),
            profileAction: .profileAction(configuration: "Release"),
            analyzeAction: .analyzeAction(configuration: "Debug")
        ),
        .scheme(
            name: "CellTunnelTunnelProvider",
            shared: true,
            buildAction: .buildAction(targets: [.target("CellTunnelTunnelProvider")]),
            runAction: .runAction(configuration: "Debug"),
            archiveAction: .archiveAction(configuration: "Release"),
            profileAction: .profileAction(configuration: "Release"),
            analyzeAction: .analyzeAction(configuration: "Debug")
        ),
    ]
)
