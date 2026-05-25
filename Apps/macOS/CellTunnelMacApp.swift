import AppKit
import CellTunnelLog
import SwiftUI

private let logger = CellTunnelLog.logger(category: .app)

@main
struct CellTunnelMacApp: App {
    @State private var tunnelStore: MacTunnelStore
    private let runsHelperCommand: Bool

    init() {
        CellTunnelLog.bootstrap()
        logger.notice("CellTunnelMac app initializing")
        let runsHelperCommand = MacHelperCommand.runIfRequested(arguments: CommandLine.arguments)
        self.runsHelperCommand = runsHelperCommand
        _tunnelStore = State(initialValue: MacTunnelStore())
        if runsHelperCommand {
            NSApplication.shared.setActivationPolicy(.accessory)
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            if runsHelperCommand {
                EmptyView()
                    .frame(width: 1, height: 1)
            } else {
                MacContentView(tunnelStore: tunnelStore)
                    .frame(minWidth: 720, minHeight: 460)
                    .task {
                        tunnelStore.performAutomaticActivationIfRequested(
                            arguments: CommandLine.arguments)
                    }
            }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // The prototype does not create document windows.
            }
        }
    }
}
