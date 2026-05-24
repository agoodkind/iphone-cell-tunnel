import CellTunnelLog

private let automaticHelperActivationArgument = "--cell-tunnel-activate-helper"
private let activationLogger = CellTunnelLog.logger(category: .store)

@MainActor
private enum MacTunnelActivationState {
    static var handled = false
}

extension MacTunnelStore {
    func performAutomaticActivationIfRequested(arguments: [String]) {
        guard !MacTunnelActivationState.handled else {
            return
        }
        MacTunnelActivationState.handled = true
        guard arguments.contains(automaticHelperActivationArgument) else {
            return
        }

        activationLogger.notice("mac automatic helper activation requested")
        refreshHelperStatus()
        switch helperState {
        case .enabled:
            return
        case .requiresApproval:
            openHelperSettings()
        case .notFound, .notRegistered, .unknown:
            installHelper()
            if helperState == .requiresApproval {
                openHelperSettings()
            }
        }
    }
}
