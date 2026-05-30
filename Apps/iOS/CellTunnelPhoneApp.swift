import CellTunnelCore
import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)

@main
struct CellTunnelPhoneApp: App {
    @State private var relayController: PhoneRelayController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CellTunnelLog.bootstrap()
        logger.notice("CellTunnelPhone app initializing")
        applyLaunchPortOverride()
        logger.notice(
            "phone app server endpoint sourced from Mac control channel; no defaults override"
        )
        _relayController = State(initialValue: PhoneRelayController())
    }

    var body: some Scene {
        WindowGroup {
            PhoneContentView(relayController: relayController)
                .task {
                    await relayController.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
        }
    }

    // The tunnel is always-on via on-demand, so backgrounding never stops it; it
    // only suspends the in-app status poll to save work, and foregrounding
    // resumes the poll with a fresh refresh.
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

// Writes the launch-provided relay listener port into the app-group UserDefaults
// the extension reads via resolvedRelayListenerPort, so a device test can pin
// the port the background provider advertises.
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
