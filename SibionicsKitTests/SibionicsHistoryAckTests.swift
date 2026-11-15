@testable import SibionicsKit
import XCTest

/// The two-byte `39` replies are the five-byte ACK form
/// `[04][cmd][status][detail][cksum]`, per Juggluco's `handle_ack` — not a
/// truncated record packet.
///
/// This matters for diagnosis rather than for delivery: `04 39 00 05` is status
/// 0, "success, nothing to send", while `04 39 01 00` is status 1, the sensor
/// *refusing* the request. Both end the batch, but only one means we asked for
/// something reasonable.
final class SibionicsHistoryAckTests: XCTestCase {
    private func reply(_ bytes: [UInt8]) -> SibionicsReply? {
        SibionicsReply(decoding: Data(bytes))
    }

    func testEmptyHistoryReplyIsAnAckWithStatusZero() throws {
        let reply = try XCTUnwrap(reply([0x04, 0x39, 0x00, 0x05, 0xBE]))
        XCTAssertTrue(reply.isAck)
        XCTAssertEqual(reply.ackStatus, 0, "status 0 is success")
        XCTAssertEqual(reply.ackDetail, 5)
        XCTAssertFalse(reply.isRejectedHistory)
    }

    func testRejectedHistoryReplyIsAnAckWithNonZeroStatus() throws {
        // Sums to zero mod 256: 4 + 0x39 + 1 + 0 = 0x3E, so the checksum is 0xC2.
        let reply = try XCTUnwrap(reply([0x04, 0x39, 0x01, 0x00, 0xC2]))
        XCTAssertTrue(reply.isAck)
        XCTAssertEqual(reply.ackStatus, 1)
        XCTAssertTrue(reply.isRejectedHistory, "status 1 is a refusal, not an empty batch")
    }

    /// A real record packet is not an ACK, however it is sized.
    func testRecordPacketIsNotAnAck() throws {
        let payload = Fixtures.glucosePayload(
            cmd: SibionicsCommand.historyRecord, startIndex: 7,
            records: [Fixtures.recordData()]
        )
        let frame = SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: payload).encoded
        let reply = try XCTUnwrap(reply([UInt8](frame)))
        XCTAssertFalse(reply.isAck)
        XCTAssertNil(reply.ackStatus)
    }
}
