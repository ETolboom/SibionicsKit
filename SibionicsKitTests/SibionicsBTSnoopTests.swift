@testable import SibionicsKit
import XCTest

/// Builds `btsnoop` files so the reader can be exercised without a phone.
/// The writer is deliberately the most obvious possible encoding of the spec,
/// so a field-order mistake in the reader shows up as a failing expectation on
/// a known frame rather than as silently empty output on a real capture.
enum BTSnoopBuilder {
    static let handle: UInt16 = 0x0031

    enum Att {
        case notification(Data)
        case writeRequest(Data)
    }

    static func file(_ records: [Att], datalink: UInt32 = 1002) -> Data {
        var data = Data("btsnoop\0".utf8)
        data.append(le32(1))
        data.append(le32(datalink))
        var timestamp: Int64 = 63_000_000_000_000_000
        for record in records {
            switch record {
            case let .notification(value),
                 let .writeRequest(value):
                let opcode: UInt8 = {
                    if case .notification = record { return 0x1B }
                    return 0x12
                }()
                var att = Data([opcode])
                att.append(le16(handle))
                att.append(value)

                var l2cap = le16(UInt16(att.count))
                l2cap.append(le16(4)) // ATT channel
                l2cap.append(att)

                var acl = le16(0x0020) // handle, PB=0
                acl.append(le16(UInt16(l2cap.count)))
                acl.append(l2cap)

                var packet = Data([0x02]) // H4 ACL, host → controller
                packet.append(acl)

                data.append(le32(UInt32(packet.count)))
                data.append(le32(UInt32(packet.count)))
                data.append(le32(0)) // flags
                data.append(le32(0)) // drops
                data.append(le64(UInt64(timestamp)))
                data.append(packet)
                timestamp += 1_000_000
            }
        }
        return data
    }

    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }

    static func le64(_ value: UInt64) -> Data {
        var out = Data()
        for index in 0 ..< 8 { out.append(UInt8((value >> (8 * UInt64(index))) & 0xFF)) }
        return out
    }
}

final class SibionicsBTSnoopTests: XCTestCase {
    private func sealed(_ frame: SibionicsFrame) throws -> Data {
        try SibionicsCipher(mac: Fixtures.mac).apply(frame.encoded)
    }

    func testReadsAnATTwWriteAndRecoversTheAuthFrame() throws {
        let auth = try SibionicsCommand.authFrame(
            mac: Fixtures.mac,
            registrationKey: Data("THE544U0TYITE461".utf8),
            accountID: try Fixtures.account()
        )
        let dump = BTSnoopBuilder.file([.writeRequest(try sealed(auth))])

        let capture = try SibionicsBTSnoop.parse(dump)
        XCTAssertEqual(capture.frames.count, 1)
        XCTAssertEqual(capture.frames[0].direction, .phone)
        XCTAssertEqual(capture.frames[0].value, try sealed(auth))
        XCTAssertNotNil(capture.startedAt)

        let decoded = try XCTUnwrap(SibionicsCaptureDecoder.decode(
            capture.frames[0].value, direction: capture.frames[0].direction, cipher: try SibionicsCipher(mac: Fixtures.mac)
        ))
        let text = decoded.notes.joined(separator: "\n")
        XCTAssertTrue(text.contains("THE544U0TYITE461"), text)
        XCTAssertTrue(text.contains(Fixtures.accountBytes.hexDescription), text)
    }

    func testReadsANotificationAsSensorTraffic() throws {
        let payload = Fixtures.glucosePayload(
            cmd: SibionicsCommand.liveRecord, startIndex: 3, records: [Fixtures.recordData()]
        )
        let frame = SibionicsFrame(cmd: SibionicsCommand.liveRecord, payload: payload)
        let dump = BTSnoopBuilder.file([.notification(try sealed(frame))])

        let capture = try SibionicsBTSnoop.parse(dump)
        XCTAssertEqual(capture.frames.count, 1)
        XCTAssertEqual(capture.frames[0].direction, .sensor)
    }

    func testInterleavedTrafficKeepsOrderAndDirection() throws {
        let a = SibionicsFrame(cmd: SibionicsCommand.infoQuery, payload: Data([0x03]))
        let b = SibionicsFrame(cmd: SibionicsCommand.auth, payload: Data([0x01, 0x00]))
        let dump = BTSnoopBuilder.file([
            .writeRequest(try sealed(a)),
            .notification(try sealed(b)),
            .writeRequest(try sealed(a))
        ])
        let capture = try SibionicsBTSnoop.parse(dump)
        XCTAssertEqual(capture.frames.map(\.direction), [.phone, .sensor, .phone])
    }

    func testRecognisesAndRejectsBadInput() {
        XCTAssertTrue(SibionicsBTSnoop.isBTSnoop(BTSnoopBuilder.file([])))
        XCTAssertFalse(SibionicsBTSnoop.isBTSnoop(Data("25e200".utf8)))
        XCTAssertThrowsError(try SibionicsBTSnoop.parse(Data("not a dump".utf8)))
    }

    func testRejectsUnsupportedDatalink() {
        let dump = BTSnoopBuilder.file([], datalink: 4242)
        XCTAssertThrowsError(try SibionicsBTSnoop.parse(dump))
    }

    func testTruncatedRecordIsAnErrorNotEmptySuccess() {
        var dump = BTSnoopBuilder.file([.writeRequest(Data([1, 2, 3, 4]))])
        dump.removeLast(6)
        XCTAssertThrowsError(try SibionicsBTSnoop.parse(dump))
    }

    /// A btsnoop timestamp is microseconds since 0000-01-01, not since 1970.
    func testTimestampEpoch() {
        // 0x00dcddb30f2f8000 µs == 1970-01-01T00:00:00Z.
        let known: Int64 = 62_167_219_200_000_000
        let date = try? XCTUnwrap(SibionicsBTSnoop.date(fromBTSnoopMicroseconds: known))
        XCTAssertEqual(date?.timeIntervalSince1970 ?? -1, 0, accuracy: 1)
    }
}
