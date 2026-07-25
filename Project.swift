//
//  Project.swift
//  CellTunnel
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import Foundation
import ProjectDescription

let projectName = "CellTunnel"
let organizationName = "goodkind.io"
let iOSDeploymentTarget = DeploymentTargets.iOS("26.0")
let macOSDeploymentTarget = DeploymentTargets.macOS("26.0")

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
    "MACOSX_DEPLOYMENT_TARGET": "26.0",
    "SYMROOT": "$(SRCROOT)/Products",
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

// Shared macOS runtime settings. Signing identity and style are added per target
// through developmentSigning below, which replaces Tuist's ad-hoc "-" target default
// for the development build; the team comes from the DEVELOPMENT_TEAM the build sets.
let macHardenedRuntimeSettings: SettingsDictionary = [
  "ENABLE_HARDENED_RUNTIME": "YES",
  "REGISTER_APP_GROUPS": "YES",
]

// Tuist evaluates this manifest in a separate process and forwards only TUIST_*
// variables to it, reachable through the Environment API; a raw host variable such
// as PROVISIONING_PROFILE_SPECIFIER is never visible here. iphone's Makefile sets
// TUIST_DEVELOPER_ID_SIGNING=1 for the signed CI build (where the engine installed
// the provisioning profiles) and leaves it unset for the dead-code coverage build
// and for local builds, so the per-target specifiers below apply only then.
let isDeveloperIdProvisioning = Environment.developerIdSigning.getBoolean(default: false)

// How each signable target signs, in two modes. The CI build (isDeveloperIdProvisioning,
// set by ci.yml) signs manually with an Apple Distribution certificate and an App Store
// provisioning profile pinned per target, because CI runs on machines that are not
// registered devices and only App Store profiles, which carry no device list, work
// there; fastlane creates and renews those profiles with the App Store Connect API key
// (see fastlane/Fastfile). Local builds sign with an Apple Development certificate and
// automatic provisioning against the developer's registered machine. The Catalyst slice
// needs the macOS-SDK identity set explicitly, because Tuist injects
// CODE_SIGN_IDENTITY[sdk=macosx*] = "-" for it, which is more specific than the generic
// key and would otherwise sign it ad-hoc.
let developmentSigning: SettingsDictionary = [
  "CODE_SIGN_IDENTITY": "Apple Development",
  "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
  "CODE_SIGN_STYLE": "Automatic",
]
let distributionSigning: SettingsDictionary = [
  "CODE_SIGN_IDENTITY": "Apple Distribution",
  "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Distribution",
  "CODE_SIGN_STYLE": "Manual",
]
let baseSigning: SettingsDictionary =
  isDeveloperIdProvisioning ? distributionSigning : developmentSigning

// The App Store profile names fastlane creates for the iPhone app and the Mac Catalyst
// slice (which shares the iPhone bundle identifier), and for the iPhone tunnel. Applied
// only in the CI distribution build; local builds provision automatically.
let phoneProvisioning: SettingsDictionary =
  isDeveloperIdProvisioning
  ? [
    "PROVISIONING_PROFILE_SPECIFIER[sdk=iphoneos*]": "Managed AppStore CellTunnelPhone iOS",
    "PROVISIONING_PROFILE_SPECIFIER[sdk=macosx*]": "Managed AppStore CellTunnelPhone Catalyst",
  ]
  : [:]
let phoneTunnelProvisioning: SettingsDictionary =
  isDeveloperIdProvisioning
  ? ["PROVISIONING_PROFILE_SPECIFIER": "Managed AppStore CellTunnelPhoneTunnel iOS"]
  : [:]

// The two macOS NetworkExtension targets carry App Groups + Network Extensions
// entitlements (the app-extension packet-tunnel-provider), so each needs its own
// provisioning profile. In the CI build, pin each macOS-only target to its App Store
// profile by name. Locally the target provisions automatically.
func macNetworkExtensionSettings(profileName: String) -> SettingsDictionary {
  var settings = macHardenedRuntimeSettings.merging(baseSigning) { _, new in new }
  if isDeveloperIdProvisioning {
    settings["PROVISIONING_PROFILE_SPECIFIER"] = SettingValue(stringLiteral: profileName)
  }
  return settings
}

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
  // The Catalyst slice signs from a macOS-only entitlements file. Both the iPhone and
  // Catalyst slices take their signing mode from baseSigning and, in the CI build,
  // their App Store profile from phoneProvisioning.
  "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]":
    "$(SRCROOT)/Apps/iOS/Entitlements/CellTunnelPhone-Catalyst.entitlements",
].merging(baseSigning) { _, new in new }
  .merging(phoneProvisioning) { _, new in new }

let appDependencies: [TargetDependency] = [
  .target(name: "CellTunnelCore"),
  .target(name: "CellTunnelLog"),
]

let tunnelProviderDependencies: [TargetDependency] =
  appDependencies + [.external(name: "WireGuardKit")]

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
      name: "CellTunnelRelay",
      destinations: [.iPhone],
      product: .framework,
      bundleId: "$(BUNDLE_ID_PREFIX).CellTunnelRelay",
      deploymentTargets: iOSDeploymentTarget,
      infoPlist: .default,
      sources: [
        "Sources/CellTunnelRelay/**"
      ],
      dependencies: appDependencies,
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
        .target(name: "CellTunnelPhoneTunnel", condition: .when([.ios])),
        // The relay runtime engine. The iPhone product hosts it in-process
        // in the simulator through SimulatorRelayBackend; the Catalyst
        // product reads the agent over XPC and does not link it.
        .target(name: "CellTunnelRelay", condition: .when([.ios])),
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
                "Generated/CellTunnelAgent/agent-launchd.plist"
            )
          ]
        )
      ],
      entitlements: .file(path: "Apps/macOS/Entitlements/Agent.entitlements"),
      dependencies: appDependencies + [
        .target(name: "CellTunnelTunnelProvider"),
        .external(name: "WireGuardKit"),
      ],
      settings: .settings(
        base: macNetworkExtensionSettings(profileName: "Managed AppStore CellTunnelAgent"))
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
      settings: .settings(
        base: macNetworkExtensionSettings(profileName: "Managed AppStore CellTunnelTunnelProvider"))
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
      dependencies: appDependencies + [.target(name: "CellTunnelRelay")],
      settings: .settings(
        base: ["REGISTER_APP_GROUPS": "YES"].merging(baseSigning) { _, new in new }
          .merging(phoneTunnelProvisioning) { _, new in new })
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
