@testable import SibionicsKit
import XCTest

final class SibionicsFrameTests: XCTestCase {
    func testAuthFrameMatchesDocumentedLayout() throws {
        let frame = try SibionicsCommand.authFrame(
            mac: Fixtures.mac,
            registrationKey: Fixtures.registrationKey,
            accountID: try Fixtures.account()
        )
        XCTAssertEqual(frame.encoded, Fixtures.authFramePlaintext)
        XCTAssertEqual(frame.encoded.count, 38)
        XCTAssertEqual(frame.encoded[0], 0x25, "len field is size - 1")
        XCTAssertEqual(frame.encoded[1], 0xE2)
        XCTAssertEqual(frame.encoded[2], 0x00, "the byte after the opcode is a constant 0x00")
    }

    func testEveryFrameSumsToZeroMod256() throws {
        let frames: [SibionicsFrame] = [
            try SibionicsCommand.authFrame(
                mac: Fixtures.mac, registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
            ),
            try SibionicsCommand.activateBindInFrame(activationTime: 0xDEAD_BEEF, accountID: try Fixtures.account()),
            SibionicsCommand.infoQueryFrame(0x0F),
            SibionicsCommand.historyRequestFrame(from: 12)
        ]
        for frame in frames {
            let sum = frame.encoded.reduce(UInt16(0)) { ($0 &+ UInt16($1)) & 0xFF }
            XCTAssertEqual(sum, 0, "\(frame.encoded.hexString) does not sum to 0 mod 256")
        }
    }

    func testLengthFieldIsPayloadPlusTwo() {
        for count in 0 ... 40 {
            let frame = SibionicsFrame(cmd: 0x39, payload: Data(repeating: 0xAB, count: count))
            XCTAssertEqual(Int(frame.lengthField), count + 2)
            XCTAssertEqual(frame.encoded.count, count + 3)
        }
    }

    func testDecodeRoundTrip() throws {
        let original = SibionicsCommand.historyRequestFrame(from: 5, to: 9)
        let decoded = try SibionicsFrame(decoding: original.encoded)
        XCTAssertEqual(decoded, original)
    }

    func testDecodeToleratesBlockPadding() throws {
        var padded = SibionicsCommand.infoQueryFrame(0x0F).encoded
        padded.append(Data(repeating: 0, count: 12))
        let decoded = try SibionicsFrame(decoding: padded)
        XCTAssertEqual(decoded.cmd, SibionicsCommand.infoQuery)
    }

    func testChecksumRejectsCorruption() {
        var corrupt = (try? SibionicsCommand.authFrame(
            mac: Fixtures.mac, registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
        ))!.encoded
        corrupt[7] ^= 0x01
        XCTAssertThrowsError(try SibionicsFrame(decoding: corrupt))
    }

    /// `len` is one byte, so 256 is the largest representable frame and 15 is
    /// the most records a history packet can hold.
    func testMaximumFrameSize() {
        XCTAssertEqual(SibionicsFrame.maxSize, 256)
        XCTAssertEqual(SibionicsFrame.maxRecordsPerPacket, 15)

        let payload = Data(repeating: 0xAB, count: SibionicsFrame.maxPayload)
        let frame = SibionicsFrame(cmd: 0x39, payload: payload)
        XCTAssertEqual(frame.lengthField, 255)
        XCTAssertEqual(frame.encoded.count, 256)

        let decoded = try? SibionicsFrame(decoding: frame.encoded)
        XCTAssertEqual(decoded?.payload.count, SibionicsFrame.maxPayload)

        // One byte more is not representable and must not decode.
        var tooBig = frame.encoded
        tooBig.append(0)
        XCTAssertThrowsError(try SibionicsFrame(decoding: tooBig, allowTrailingPadding: false))
    }

    func testRejectsTruncatedInput() {
        XCTAssertThrowsError(try SibionicsFrame(decoding: Data([0x05, 0xE2])))
        XCTAssertThrowsError(try SibionicsFrame(decoding: Data()))
    }
}
