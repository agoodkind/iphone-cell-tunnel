import CellTunnelCore
import Foundation
import XCTest

final class RelayCodecTests: XCTestCase {
    func testFrameRoundTripPreservesHeaderAndPayload() throws {
        let payload = Data("hello".utf8)
        let frame = RelayFrame(
            streamID: 42,
            operation: .wireGuardDatagram,
            addressFamily: .ipv6,
            flags: 7,
            payload: payload
        )

        let encodedFrame = RelayCodec.encode(frame)
        let decodedFrame = try RelayCodec.decode(encodedFrame)

        XCTAssertEqual(decodedFrame, frame)
    }

    func testWireGuardDatagramFramePreservesOpaqueIPv4EndpointPayload() throws {
        let datagram = Data([0x00, 0x01, 0xfe, 0xff, 0x45, 0x00, 0x00, 0x14])
        let relayDatagram = try WireGuardDatagram(data: datagram, addressFamily: .ipv4)
        let frame = relayDatagram.relayFrame(streamID: 7)
        let decodedFrame = try RelayCodec.decode(RelayCodec.encode(frame))
        let decodedDatagram = try WireGuardDatagram(frame: decodedFrame)

        XCTAssertEqual(frame.operation, .wireGuardDatagram)
        XCTAssertEqual(decodedFrame.payload, datagram)
        XCTAssertEqual(decodedDatagram.data, datagram)
        XCTAssertEqual(decodedDatagram.addressFamily, .ipv4)
    }

    func testWireGuardDatagramFramePreservesOpaqueIPv6EndpointPayload() throws {
        let datagram = Data([0x04, 0x00, 0x00, 0x00, 0x60, 0x00, 0x00, 0x00])
        let relayDatagram = try WireGuardDatagram(data: datagram, addressFamily: .ipv6)
        let frame = relayDatagram.relayFrame(streamID: 8)
        let decodedFrame = try RelayCodec.decode(RelayCodec.encode(frame))
        let decodedDatagram = try WireGuardDatagram(frame: decodedFrame)

        XCTAssertEqual(frame.operation, .wireGuardDatagram)
        XCTAssertEqual(decodedFrame.payload, datagram)
        XCTAssertEqual(decodedDatagram.data, datagram)
        XCTAssertEqual(decodedDatagram.addressFamily, .ipv6)
    }

    func testWireGuardDatagramRejectsWrongOperation() {
        let frame = RelayFrame(
            streamID: 9,
            operation: .pathStatus,
            addressFamily: .ipv6,
            payload: Data([0x01])
        )

        XCTAssertThrowsError(try WireGuardDatagram(frame: frame)) { error in
            XCTAssertEqual(
                error as? WireGuardDatagramError,
                .unexpectedOperation(.pathStatus)
            )
        }
    }

    func testHandshakePayloadParsesWireGuardEndpoint() throws {
        let endpoint = RelayEndpoint(addressFamily: .ipv6, host: "2001:db8::1", port: 51_820)
        let payload = RelayHandshakePayload(wireGuardServer: endpoint)
        let decodedPayload = try RelayHandshakePayload.decode(payload.encoded())

        XCTAssertEqual(decodedPayload.wireGuardServer, endpoint)
    }
}
