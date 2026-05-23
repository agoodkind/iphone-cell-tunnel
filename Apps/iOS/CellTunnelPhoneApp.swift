import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)

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
        }
    }
}
