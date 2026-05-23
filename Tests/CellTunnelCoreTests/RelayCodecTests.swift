import CellTunnelCore
import Foundation
import XCTest

final class RelayCodecTests: XCTestCase {
    func testFrameRoundTripPreservesHeaderAndPayload() throws {
        let payload = Data("hello".utf8)
        let frame = RelayFrame(
            streamID: 42,
            operation: .tcpData,
            addressFamily: .ipv6,
            flags: 7,
            payload: payload
        )

        let encodedFrame = RelayCodec.encode(frame)
        let decodedFrame = try RelayCodec.decode(encodedFrame)

        XCTAssertEqual(decodedFrame, frame)
    }
}
