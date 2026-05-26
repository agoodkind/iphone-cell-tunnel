import CellTunnelLog
import Darwin
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

private let utunControlName = "com.apple.net.utun_control"

// CTLIOCGINFO from <sys/kern_control.h>. The system header defines this via
// the _IOWR macro which the Swift importer cannot translate; redeclared as a
// plain constant so the value reaches Swift call sites unchanged.
private let ctlInfoIoctl: UInt = 0xc064_4e03

enum UtunDeviceError: LocalizedError {
    case socketFailed(errno: Int32)
    case ctlInfoFailed(errno: Int32)
    case connectFailed(errno: Int32)
    case interfaceNameFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let code):
            return "utun PF_SYSTEM socket() failed errno=\(code)"
        case .ctlInfoFailed(let code):
            return "utun CTLIOCGINFO ioctl() failed errno=\(code)"
        case .connectFailed(let code):
            return "utun connect() failed errno=\(code)"
        case .interfaceNameFailed(let code):
            return "utun UTUN_OPT_IFNAME getsockopt() failed errno=\(code)"
        }
    }
}

final class UtunDevice {
    let fileDescriptor: Int32
    let interfaceName: String
    private var isClosed = false

    init() throws {
        let socketDescriptor = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard socketDescriptor >= 0 else {
            throw UtunDeviceError.socketFailed(errno: errno)
        }

        var controlInfo = ctl_info()
        withUnsafeMutablePointer(to: &controlInfo.ctl_name) { namePointer in
            namePointer.withMemoryRebound(
                to: CChar.self,
                capacity: MemoryLayout.size(ofValue: namePointer.pointee)
            ) { rebound in
                _ = strcpy(rebound, utunControlName)
            }
        }
        if ioctl(socketDescriptor, ctlInfoIoctl, &controlInfo) != 0 {
            let code = errno
            Darwin.close(socketDescriptor)
            throw UtunDeviceError.ctlInfoFailed(errno: code)
        }

        // Kernel assigns a free unit when sc_unit=0; first successful connect wins.
        var addressControl = sockaddr_ctl()
        addressControl.sc_id = controlInfo.ctl_id
        addressControl.sc_len = UInt8(MemoryLayout<sockaddr_ctl>.size)
        addressControl.sc_family = UInt8(AF_SYSTEM)
        addressControl.ss_sysaddr = UInt16(AF_SYS_CONTROL)
        addressControl.sc_unit = 0
        var connectStatus: Int32 = -1
        withUnsafePointer(to: &addressControl) { controlPointer in
            controlPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { genericPointer in
                connectStatus = Darwin.connect(
                    socketDescriptor,
                    genericPointer,
                    socklen_t(MemoryLayout<sockaddr_ctl>.size)
                )
            }
        }
        if connectStatus != 0 {
            let code = errno
            Darwin.close(socketDescriptor)
            throw UtunDeviceError.connectFailed(errno: code)
        }

        var nameBuffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        var nameLength = socklen_t(IFNAMSIZ)
        let nameStatus = nameBuffer.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else {
                return -1
            }
            return getsockopt(
                socketDescriptor,
                SYSPROTO_CONTROL,
                2,
                base,
                &nameLength
            )
        }
        if nameStatus != 0 {
            let code = errno
            Darwin.close(socketDescriptor)
            throw UtunDeviceError.interfaceNameFailed(errno: code)
        }

        fileDescriptor = socketDescriptor
        interfaceName = String(cString: nameBuffer)
        logger.notice(
            """
            utun device opened interface=\(self.interfaceName, privacy: .public) \
            fd=\(socketDescriptor, privacy: .public)
            """
        )
    }

    deinit {
        closeInternal()
    }

    func close() {
        closeInternal()
    }

    private func closeInternal() {
        guard !isClosed else {
            return
        }
        isClosed = true
        let status = Darwin.close(fileDescriptor)
        if status != 0 {
            logger.error(
                """
                utun device close failed interface=\(self.interfaceName, privacy: .public) \
                fd=\(self.fileDescriptor, privacy: .public) errno=\(errno, privacy: .public)
                """
            )
            return
        }
        logger.notice(
            """
            utun device closed interface=\(self.interfaceName, privacy: .public) \
            fd=\(self.fileDescriptor, privacy: .public)
            """
        )
    }
}
