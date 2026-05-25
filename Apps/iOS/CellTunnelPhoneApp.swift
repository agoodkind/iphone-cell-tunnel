import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)
private let automaticRelayStartArgument = "--cell-tunnel-start-relay"

@main
struct CellTunnelPhoneApp: App {
    @State private var relayController: PhoneRelayController

    init() {
        CellTunnelLog.bootstrap()
        logger.notice("CellTunnelPhone app initializing")
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
