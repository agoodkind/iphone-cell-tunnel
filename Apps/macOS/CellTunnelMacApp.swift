import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)

@main
struct CellTunnelMacApp: App {
    @State private var tunnelStore: MacTunnelStore

    init() {
        CellTunnelLog.bootstrap()
        logger.notice("CellTunnelMac app initializing")
        _tunnelStore = State(initialValue: MacTunnelStore())
    }

    var body: some Scene {
        WindowGroup {
            MacContentView(tunnelStore: tunnelStore)
                .frame(minWidth: 720, minHeight: 460)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // The prototype does not create document windows.
            }
        }
    }
}
