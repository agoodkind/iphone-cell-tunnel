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
                    relayController.start()
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        relayController.start()
                    } else if phase == .background {
                        relayController.stop()
                    }
                }
        }
    }
}

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
    storeRelayListenerPort(port)
    logger.notice(
        "phone app launch port argument applied port=\(port, privacy: .public)")
}
