import CellTunnelCore
import CellTunnelLog
import Foundation

private let logger = CellTunnelLog.logger(category: .daemon)

final class AgentXPCServer: NSObject, NSXPCListenerDelegate, AgentControlXPC, @unchecked Sendable {
    private let controller: AgentTunnelController
    private let onActivity: @Sendable () -> Void

    init(controller: AgentTunnelController, onActivity: @escaping @Sendable () -> Void) {
        self.controller = controller
        self.onActivity = onActivity
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        _ = listener
        newConnection.exportedInterface = NSXPCInterface(with: AgentControlXPC.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = {
            logger.notice("agent xpc inbound connection invalidated")
        }
        newConnection.resume()
        logger.notice("agent accepted inbound xpc connection")
        return true
    }

    func sendRequest(_ payload: Data, withReply reply: @escaping (Data?) -> Void) {
        onActivity()
        let replyBox = ReplyBox(reply: reply)
        let request: AgentControlRequest
        do {
            request = try JSONDecoder().decode(AgentControlEnvelope.self, from: payload).request
        } catch {
            logger.error(
                """
                agent request decode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-failure
                """
            )
            let message = "request decode failed: \(error.localizedDescription)"
            replyBox.send(encodeFailure(message: message))
            return
        }
        Task {
            let response = await controller.handle(request: request)
            replyBox.send(self.encode(response: response))
        }
    }

    private func encode(response: AgentControlResponse) -> Data? {
        do {
            return try JSONEncoder().encode(response)
        } catch {
            logger.error(
                """
                agent response encode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-failure
                """
            )
            return encodeFailure(message: "response encode failed")
        }
    }

    private func encodeFailure(message: String) -> Data? {
        let response = AgentControlResponse(
            failure: AgentControlFailure(errorCode: .internal, message: message)
        )
        do {
            return try JSONEncoder().encode(response)
        } catch {
            logger.error(
                """
                agent failure encode failed \
                details=\(String(describing: error), privacy: .public) \
                recovery=reply-nil
                """
            )
            return nil
        }
    }
}

private final class ReplyBox: @unchecked Sendable {
    private let reply: (Data?) -> Void
    private let lock = NSLock()
    private var sent = false

    init(reply: @escaping (Data?) -> Void) {
        self.reply = reply
    }

    func send(_ data: Data?) {
        lock.lock()
        if sent {
            lock.unlock()
            return
        }
        sent = true
        lock.unlock()
        reply(data)
    }
}
