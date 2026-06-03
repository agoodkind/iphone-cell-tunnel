//
//  CellTunnelPhoneApp.swift
//  CellTunnelPhone
//
//  Created by Alexander Goodkind <alex@goodkind.io> on 2026-05-23.
//  Copyright © 2026, all rights reserved.
//

import CellTunnelCore
import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)

// MARK: - CellTunnelPhoneApp

/// The app entry point for both platforms. The iPhone build drives the on-device
/// relay through `PhoneRelayBackend`. The Mac build reads the headless agent over
/// XPC through `AgentRelayBackend`. Both feed the same `RelayController`, so the
/// screens are identical.
@main
struct CellTunnelPhoneApp: App {
    @State private var relayController: RelayController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CellTunnelLog.bootstrap()
        logger.notice("CellTunnelPhone app initializing")
        applyLaunchPortOverride()
        _relayController = State(initialValue: RelayController(backend: Self.makeBackend()))
    }

    private static func makeBackend() -> any RelayControlBackend {
        #if targetEnvironment(macCatalyst)
            logger.notice("phone app selecting Mac agent backend")
            return AgentRelayBackend()
        #elseif targetEnvironment(simulator)
            logger.notice("phone app selecting simulator relay backend")
            return SimulatorRelayBackend()
        #else
            logger.notice("phone app selecting iPhone relay backend")
            return PhoneRelayBackend()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            PhoneContentView(controller: relayController)
                .task {
                    await relayController.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
        }
    }

    // The tunnel is always-on via on-demand, so backgrounding never stops it; it
    // only suspends the in-app status poll to save work, and foregrounding resumes
    // the poll with a fresh refresh.
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            logger.notice("phone app scene phase active; resuming status poll")
            relayController.resumePolling()
        case .background:
            logger.notice("phone app scene phase background; suspending status poll")
            relayController.suspendPolling()
        default:
            break
        }
    }
}

// MARK: - Launch port override

#if targetEnvironment(macCatalyst)
    // The launch-port override pins the port the iPhone background provider
    // advertises for a device test. The Mac build hosts no provider, so it is a
    // no-op there.
    private func applyLaunchPortOverride() {
        // The Mac build hosts no background provider, so there is no port to pin.
    }
#else
    // Writes the launch-provided relay listener port into the app-group
    // UserDefaults the extension reads via resolvedRelayListenerPort, so a device
    // test can pin the port the background provider advertises.
    private func applyLaunchPortOverride() {
        let arguments = CommandLine.arguments
        guard let argumentIndex = arguments.firstIndex(of: relayListenerPortLaunchArgument) else {
            return
        }
        let valueIndex = arguments.index(after: argumentIndex)
        guard valueIndex < arguments.endIndex else {
            logger.notice("phone app launch port argument missing value")
            return
        }
        guard let port = UInt16(arguments[valueIndex]), port >= 1 else {
            logger.notice(
                """
                phone app launch port argument invalid \
                value=\(arguments[valueIndex], privacy: .public)
                """
            )
            return
        }
        let defaults = UserDefaults(suiteName: cellTunnelAppGroupIdentifier) ?? .standard
        storeRelayListenerPort(port, defaults: defaults)
        logger.notice(
            "phone app launch port argument applied port=\(port, privacy: .public)")
    }
#endif
