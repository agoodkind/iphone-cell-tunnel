import Foundation
import ProjectDescription

let projectName = "CellTunnel"
let organizationName = "goodkind.io"
let iOSDeploymentTarget = DeploymentTargets.iOS("26.0")
let macOSDeploymentTarget = DeploymentTargets.macOS("15.0")

// Build configurations are driven by xcconfig files. Config/Constants.xcconfig
// holds bundle identifiers, mach service name, executable name, and app group.
// Config/local.xcconfig (gitignored) holds DEVELOPMENT_TEAM, CODE_SIGN_IDENTITY,
// and CODE_SIGN_STYLE. debug.xcconfig and release.xcconfig pull both in.
let debug = Configuration.debug(name: "Debug", xcconfig: "Config/debug.xcconfig")
let release = Configuration.release(name: "Release", xcconfig: "Config/release.xcconfig")

let projectSettings = Settings.settings(
    base: [
        "SWIFT_VERSION": "6.0",
        "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
        "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
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

// Tuist writes CODE_SIGN_IDENTITY = "-" (ad-hoc) at target level by default,
// which would override the xcconfig values. Forwarding $(KEY) references at
// the target level lets the xcconfig values come through unchanged.
let macHardenedRuntimeSettings: SettingsDictionary = [
    "ENABLE_HARDENED_RUNTIME": "YES",
    "REGISTER_APP_GROUPS": "YES",
    "CODE_SIGN_IDENTITY": "$(CODE_SIGN_IDENTITY)",
    "CODE_SIGN_STYLE": "$(CODE_SIGN_STYLE)",
    "DEVELOPMENT_TEAM": "$(DEVELOPMENT_TEAM)",
]

let cellTunnelPhoneBaseSettings: SettingsDictionary = [
    "PRODUCT_NAME": "CellTunnelPhone",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
    "REGISTER_APP_GROUPS": "YES",
    // The Mac Catalyst build keeps the iPhone bundle identifier so it stays in the
    // same app group, and signs from a Catalyst-only entitlements file that adds
    // the mach-lookup allowance for the agent service and drops the tunnel
    // entitlement. Adding .macCatalyst to the destinations turns on
    // SUPPORTS_MACCATALYST.
    "DERIVE_MACCATALYST_PRODUCT_BUNDLE_IDENTIFIER": "NO",
    "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]":
        "$(SRCROOT)/Apps/iOS/Entitlements/CellTunnelPhone-Catalyst.entitlements",
    // Tuist writes CODE_SIGN_IDENTITY = "-" (ad-hoc) at target level for the macOS
    // SDK, which the Catalyst entitlements reject because they require a
    // development certificate. Forwarding the xcconfig signing values for the
    // macOS SDK only lets the Catalyst slice sign like the Mac agent while the
    // iPhone slice is untouched.
    "CODE_SIGN_IDENTITY[sdk=macosx*]": "$(CODE_SIGN_IDENTITY)",
    "CODE_SIGN_STYLE[sdk=macosx*]": "$(CODE_SIGN_STYLE)",
    "DEVELOPMENT_TEAM[sdk=macosx*]": "$(DEVELOPMENT_TEAM)",
]

let appDependencies: [TargetDependency] = [
    .target(name: "CellTunnelCore"),
    .target(name: "CellTunnelLog"),
]

let tunnelProviderDependencies: [TargetDependency] =
    appDependencies + [.external(name: "WireGuardKit")]

// Pre-build scripts re-render the xcconfig-driven templates each build, so
// the rendered files survive a `tuist generate` (which clears
// Derived/Generated/). xcodebuild exports xcconfig values as env, so the
// same [[KEY]] substitutions used by `make xcconfig-generate-config` apply
// here too.
let xcconfigEnvKeys =
    "AGENT_BUNDLE_ID PROVIDER_BUNDLE_ID PHONE_BUNDLE_ID "
    + "AGENT_MACH_SERVICE_NAME AGENT_XPC_SESSION_SERVICE_NAME "
    + "AGENT_LAUNCH_AGENT_PLIST_NAME "
    + "AGENT_EXECUTABLE_NAME AGENT_APP_BUNDLE_NAME "
    + "APP_GROUP_ID BUNDLE_ID_PREFIX"

let renderConfigGeneratedScript = TargetScript.pre(
    script: #"""
        "$SRCROOT/.make/swift-mk" render-batch \
            --templates-dir "$SRCROOT/Templates/Swift" \
            --output-dir "$SRCROOT/Sources/CellTunnelCore/Generated" \
            --env TARGET_NAME \#(xcconfigEnvKeys)
        """#,
    name: "Render CellTunnelCore Config.generated.swift",
    inputPaths: [
        "$(SRCROOT)/Templates/Swift/Config.generated.swift.template"
    ],
    outputPaths: [
        "$(SRCROOT)/Sources/CellTunnelCore/Generated/Config.generated.swift"
    ]
)

let renderAgentLaunchdScript = TargetScript.pre(
    script: #"""
        "$SRCROOT/.make/swift-mk" render-batch \
            --templates-dir "$SRCROOT/Templates/Plists" \
            --output-dir "$SRCROOT/Derived/Generated/CellTunnelAgent" \
            --env TARGET_NAME \#(xcconfigEnvKeys)
        """#,
    name: "Render CellTunnelAgent agent-launchd.plist",
    inputPaths: [
        "$(SRCROOT)/Templates/Plists/agent-launchd.plist.template"
    ],
    outputPaths: [
        "$(SRCROOT)/Derived/Generated/CellTunnelAgent/agent-launchd.plist"
    ]
)

let project = Project(
    name: projectName,
    organizationName: organizationName,
    packages: [],
    settings: projectSettings,
    targets: [
        .target(
            name: "CellTunnelCore",
            destinations: [.iPhone, .mac, .macCatalyst],
            product: .framework,
            bundleId: "$(BUNDLE_ID_PREFIX).CellTunnelCore",
            infoPlist: .default,
            sources: [
                "Sources/CellTunnelCore/**"
            ],
            scripts: [renderConfigGeneratedScript],
            dependencies: [.target(name: "CellTunnelLog")],
            settings: .settings(base: moduleVerifierSettings)
        ),
        .target(
            name: "CellTunnelLog",
            destinations: [.iPhone, .mac, .macCatalyst],
            product: .framework,
            bundleId: "$(BUNDLE_ID_PREFIX).CellTunnelLog",
            infoPlist: .default,
            sources: [
                "Sources/CellTunnelLog/**"
            ],
            settings: .settings(base: moduleVerifierSettings)
        ),
        .target(
            name: "CellTunnelPhone",
            destinations: [.iPhone, .macCatalyst],
            product: .app,
            bundleId: "$(PHONE_BUNDLE_ID)",
            deploymentTargets: iOSDeploymentTarget,
            infoPlist: .file(path: "Apps/iOS/Info.plist"),
            sources: [
                "Apps/iOS/**"
            ],
            entitlements: .file(path: "Apps/iOS/Entitlements/CellTunnelPhone.entitlements"),
            dependencies: appDependencies + [
                // The iPhone build embeds the relay tunnel extension. The Mac
                // Catalyst build hosts no tunnel and reads the agent over XPC, so
                // the extension is scoped to iPhone to keep it out of the Catalyst
                // product and avoid a duplicate framework producer.
                .target(name: "CellTunnelPhoneTunnel", condition: .when([.ios]))
            ],
            settings: .settings(base: cellTunnelPhoneBaseSettings)
        ),
        .target(
            name: "CellTunnelAgent",
            destinations: [.mac],
            product: .app,
            bundleId: "$(AGENT_BUNDLE_ID)",
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
                                "Derived/Generated/CellTunnelAgent/agent-launchd.plist"
                        )
                    ]
                )
            ],
            entitlements: .file(path: "Apps/macOS/Entitlements/Agent.entitlements"),
            scripts: [renderAgentLaunchdScript],
            dependencies: appDependencies + [
                .target(name: "CellTunnelTunnelProvider"),
                .external(name: "WireGuardKit"),
            ],
            settings: .settings(base: macHardenedRuntimeSettings)
        ),
        .target(
            name: "CellTunnelTunnelProvider",
            destinations: [.mac],
            product: .appExtension,
            bundleId: "$(PROVIDER_BUNDLE_ID)",
            deploymentTargets: macOSDeploymentTarget,
            infoPlist: .file(path: "Apps/macOS/TunnelProvider/Info.plist"),
            sources: [
                "Apps/macOS/TunnelProvider/**"
            ],
            entitlements: .file(path: "Apps/macOS/Entitlements/TunnelProvider.entitlements"),
            dependencies: tunnelProviderDependencies,
            settings: .settings(base: macHardenedRuntimeSettings)
        ),
        .target(
            name: "CellTunnelPhoneTunnel",
            destinations: [.iPhone],
            product: .appExtension,
            bundleId: "$(PHONE_PROVIDER_BUNDLE_ID)",
            deploymentTargets: iOSDeploymentTarget,
            infoPlist: .file(path: "Apps/PhoneTunnelProvider/Info.plist"),
            sources: [
                "Apps/PhoneTunnelProvider/**"
            ],
            entitlements: .file(
                path: "Apps/iOS/Entitlements/CellTunnelPhoneTunnel.entitlements"
            ),
            dependencies: appDependencies,
            settings: .settings(base: ["REGISTER_APP_GROUPS": "YES"])
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
        .scheme(
            name: "CellTunnelPhoneTunnel",
            shared: true,
            buildAction: .buildAction(targets: [.target("CellTunnelPhoneTunnel")]),
            runAction: .runAction(configuration: "Debug"),
            archiveAction: .archiveAction(configuration: "Release"),
            profileAction: .profileAction(configuration: "Release"),
            analyzeAction: .analyzeAction(configuration: "Debug")
        ),
    ]
)
