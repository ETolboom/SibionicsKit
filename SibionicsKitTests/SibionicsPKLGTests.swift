@testable import SibionicsKit
import XCTest

/// Apple's PacketLogger container:
/// `[u32 length][u32 seconds][u32 microseconds][u8 type][…]`, with `length`
/// counting everything after itself.
enum PKLGBuilder {
    enum Record {
        case attFromPhone(Data)
        case attFromSensor(Data)
        case log(String)
    }

    static func file(_ records: [Record], baseTime: UInt32 = 1_794_704_891) -> Data {
        var data = Data()
        var micros: UInt32 = 0
        for record in records {
            var body = Data()
            switch record {
            case let .attFromPhone(value):
                body = acl(att: writeRequest(value))
            case let .attFromSensor(value):
                body = acl(att: notification(value))
            case let .log(text):
                body = Data(text.utf8)
            }
            let type: UInt8
            switch record {
            case .attFromPhone: type = 2
            case .attFromSensor: type = 3
            case .log: type = 252
            }

            var payload = le32(baseTime) + le32(micros) + Data([type]) + body
            data.append(le32(UInt32(payload.count)))
            data.append(payload)
            payload.removeAll()
            micros += 1000
        }
        return data
    }

    private static func writeRequest(_ value: Data) -> Data {
        var att = Data([0x12])
        att.append(le16(0x0029))
        att.append(value)
        return att
    }

    private static func notification(_ value: Data) -> Data {
        var att = Data([0x1B])
        att.append(le16(0x0026))
        att.append(value)
        return att
    }

    private static func acl(att: Data) -> Data {
        var l2cap = le16(UInt16(att.count))
        l2cap.append(le16(4))
        l2cap.append(att)
        var acl = le16(0x0020)
        acl.append(le16(UInt16(l2cap.count)))
        acl.append(l2cap)
        return acl
    }

    static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)])
    }
}

final class SibionicsPKLGTests: XCTestCase {
    private func cipher() throws -> SibionicsCipher { try SibionicsCipher(mac: Fixtures.mac) }

    func testReadsTheRealHandshakeOutOfAPKLG() throws {
        let dump = PKLGBuilder.file([
            .attFromPhone(Fixtures.authFrameCiphertext),
            .attFromSensor(Fixtures.authAckCiphertext)
        ])
        XCTAssertTrue(SibionicsPKLG.looksLikePKLG(dump))

        let capture = try SibionicsPKLG.parse(dump)
        XCTAssertEqual(capture.frames.count, 2)
        XCTAssertEqual(capture.frames[0].direction, .phone)
        XCTAssertEqual(capture.frames[1].direction, .sensor)
        XCTAssertEqual(try cipher().apply(capture.frames[0].value), Fixtures.authFramePlaintext)
        XCTAssertEqual(try cipher().apply(capture.frames[1].value), Fixtures.authAckPlaintext)
    }

    /// The format sniff sits one field away from a plausible-looking wrong
    /// answer, so pin it: the type byte follows two `u32`s after the length.
    func testSniffUsesTheTypeByteSlotNotTheTimestamp() {
        let dump = PKLGBuilder.file([.log("Product: iPhone18,1")])
        XCTAssertTrue(SibionicsPKLG.looksLikePKLG(dump))
        XCTAssertFalse(SibionicsBTSnoop.isBTSnoop(dump))
    }

    func testLogRecordsAreIgnoredButKeepOrdering() throws {
        let dump = PKLGBuilder.file([
            .log("Firmware Version: …"),
            .attFromPhone(Fixtures.authFrameCiphertext),
            .log("Chipset: Apple N1"),
            .attFromSensor(Fixtures.authAckCiphertext)
        ])
        let capture = try SibionicsPKLG.parse(dump)
        XCTAssertEqual(capture.frames.map(\.direction), [.phone, .sensor])
    }

    func testTruncatedRecordIsAnError() {
        var dump = PKLGBuilder.file([.attFromPhone(Fixtures.authFrameCiphertext)])
        dump.removeLast(5)
        XCTAssertThrowsError(try SibionicsPKLG.parse(dump))
    }

    func testCaptureWithNoTrafficIsReported() {
        let dump = PKLGBuilder.file([.log("nothing here")])
        XCTAssertThrowsError(try SibionicsPKLG.parse(dump))
    }

    func testEmptyFile() {
        XCTAssertThrowsError(try SibionicsPKLG.parse(Data()))
    }

    /// End to end: a whole captured conversation, decoded the way the CLI does.
    func testWholeCapturedConversationRoundTrips() throws {
        var records: [PKLGBuilder.Record] = []
        let cipher = try cipher()
        for entry in Fixtures.trace {
            let plaintext = Data(hex: entry.plaintext)
            let sealed = try cipher.apply(plaintext)
            records.append(entry.direction == "phone" ? .attFromPhone(sealed) : .attFromSensor(sealed))
        }
        let capture = try SibionicsPKLG.parse(PKLGBuilder.file(records))
        XCTAssertEqual(capture.frames.count, Fixtures.trace.count)

        for (frame, expected) in zip(capture.frames, Fixtures.trace) {
            let reply = try XCTUnwrap(SibionicsCaptureDecoder.decode(
                frame.value, direction: frame.direction, cipher: cipher
            ))
            XCTAssertEqual(reply.plaintext, Data(hex: expected.plaintext))
        }
    }
}
