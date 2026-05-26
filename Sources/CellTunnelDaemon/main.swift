import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

CellTunnelLog.bootstrap()
logger.notice("celltunneld booted")

print("celltunneld scaffold ready")
