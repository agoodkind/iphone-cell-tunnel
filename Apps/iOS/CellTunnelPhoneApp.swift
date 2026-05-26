import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)
private let automaticRelayStartArgument = "--cell-tunnel-start-relay"

@MainActor private var benchListenerInstance: BenchListener?

@main
struct CellTunnelPhoneApp: App {
    @State private var relayController: PhoneRelayController

    init() {
        CellTunnelLog.bootstrap()
        logger.notice("CellTunnelPhone app initializing")
        applyLaunchPortOverride()
        applyBenchModeIfRequested()
        logger.notice(
            "phone app server endpoint sourced from Mac control channel; no defaults override"
        )
        _relayController = State(initialValue: PhoneRelayController())
    }

    var body: some Scene {
        WindowGroup {
            PhoneContentView(relayController: relayController)
                .task {
                    if CommandLine.arguments.contains(automaticRelayStartArgument) {
                        logger.notice("phone app automatic relay start requested")
                        relayController.start()
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

@MainActor
private func applyBenchModeIfRequested() {
    guard CommandLine.arguments.contains(benchModeLaunchArgument) else { return }
    let listener = BenchListener()
    listener.start()
    benchListenerInstance = listener
    logger.notice("phone app bench mode enabled")
}
