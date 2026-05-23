import struct OSLog.Logger
import struct OSLog.OSSignposter

public enum CellTunnelLog {
    public static let subsystem = "io.goodkind.celltunnel"

    public enum Category: String, Sendable {
        case app
        case daemon
        case relay
        case store
    }

    public static func bootstrap() {
        bootstrapLogger.notice("Cell Tunnel logging bootstrapped")
    }

    public static func logger(category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    public static func signposter(category: Category) -> OSSignposter {
        OSSignposter(subsystem: subsystem, category: category.rawValue)
    }

    private static let bootstrapLogger = Logger(subsystem: subsystem, category: "bootstrap")
}
