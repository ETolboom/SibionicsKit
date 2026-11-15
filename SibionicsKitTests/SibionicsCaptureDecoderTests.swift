@testable import SibionicsKit
import XCTest

/// The capture decoder is what turns a rooted-phone trace into protocol
/// answers, so it is worth pinning down: a wrong annotation would send the
/// hardware testing in the wrong direction.
final class SibionicsCaptureDecoderTests: XCTestCase {
    private func cipher() throws -> SibionicsCipher { try SibionicsCipher(mac: Fixtures.mac) }

    private func sealed(_ frame: SibionicsFrame) throws -> Data {
        try cipher().apply(frame.encoded)
    }

    private func decoded(_ frame: SibionicsFrame, _ direction: SibionicsCaptureDecoder.Direction) throws
        -> SibionicsCaptureDecoder.Decoded
    {
        let sealed = try sealed(frame)
        return try XCTUnwrap(SibionicsCaptureDecoder.decode(sealed, direction: direction, cipher: try cipher()))
    }

    func testAuthRequestAnnotationRecoversRegistrationKeyAndAccountID() throws {
        let request = try SibionicsCommand.authFrame(
            mac: Fixtures.mac,
            registrationKey: Data("THE544U0TYITE461".utf8),
            accountID: try Fixtures.account()
        )
        let result = try decoded(request, .phone)
        let text = result.notes.joined(separator: "\n")

        XCTAssertTrue(text.contains("AUTH"), text)
        XCTAssertTrue(text.contains("THE544U0TYITE461"), "registration key text should be recovered:\n\(text)")
        XCTAssertTrue(text.contains("sijoy"), "the known key should be identified:\n\(text)")
        XCTAssertTrue(text.contains("verified"), text)
        XCTAssertTrue(
            text.contains(Fixtures.accountBytes.hexDescription),
            "account id should be printed:\n\(text)"
        )
    }

    func testAuthAckInterpretation() throws {
        let ack = SibionicsFrame(cmd: SibionicsCommand.auth, payload: Data([0x01, 0x00]))
        let result = try decoded(ack, .sensor)
        XCTAssertTrue(result.notes.joined().contains("status=0x01"))

        let refusal = SibionicsFrame(cmd: SibionicsCommand.auth, payload: Data([0x02, 0x00]))
        let refused = try decoded(refusal, .sensor)
        XCTAssertTrue(refused.notes.joined().contains("status=0x02"))
    }

    func testActivationAnnotationShowsTimestampAndAccount() throws {
        let frame = try SibionicsCommand.activateBindInFrame(
            activationTime: 1_700_000_000, accountID: try Fixtures.account()
        )
        let result = try decoded(frame, .phone)
        let text = result.notes.joined(separator: "\n")
        XCTAssertTrue(text.contains("ACTIVATE"))
        XCTAssertTrue(text.contains("1700000000"), text)
        XCTAssertTrue(text.contains("2023-11-14"), "the timestamp should be readable:\n\(text)")
        XCTAssertTrue(text.contains(Fixtures.accountBytes.hexDescription))
    }

    func testDeviceTimeAnnotation() throws {
        // A reply echoes its sub-opcode first.
        var payload = Data([SibionicsCommand.infoDeviceTime])
        payload.append(Fixtures.deviceTimePayload(
            activation: 1_700_000_000, current: 1_700_003_600, last: 1_700_003_300, lastIndex: 60
        ))
        let frame = SibionicsFrame(cmd: SibionicsCommand.infoQuery, payload: payload)
        let text = try decoded(frame, .sensor).notes.joined(separator: "\n")
        XCTAssertTrue(text.contains("activation=1700000000"), text)
        XCTAssertTrue(text.contains("lastIndex=60"), text)
        XCTAssertTrue(text.contains("elapsed=3600s"), text)
    }

    func testLiveRecordAnnotation() throws {
        let payload = Fixtures.glucosePayload(
            cmd: SibionicsCommand.liveRecord, startIndex: 7, records: [Fixtures.recordData()]
        )
        let frame = SibionicsFrame(cmd: SibionicsCommand.liveRecord, payload: payload)
        let text = try decoded(frame, .sensor).notes.joined(separator: "\n")
        XCTAssertTrue(text.contains("live 0x32"), text)
        XCTAssertTrue(text.contains("#7"), text)
        XCTAssertTrue(text.contains("5.7 mmol/L"), text)
    }

    func testEmptyHistoryPacketIsCalledOutAsTheTerminator() throws {
        let payload = Fixtures.glucosePayload(cmd: SibionicsCommand.historyRecord, startIndex: 0, records: [])
        let frame = SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: payload)
        let text = try decoded(frame, .sensor).notes.joined(separator: "\n")
        XCTAssertTrue(text.contains("batch terminator"), text)
    }

    // MARK: - Line parsing

    func testParseLineHandlesDirectionsAndNoise() {
        let plain = SibionicsCaptureDecoder.parseLine("25e200ff")
        XCTAssertEqual(plain?.bytes, Data([0x25, 0xE2, 0x00, 0xFF]))
        XCTAssertNil(plain?.direction)

        XCTAssertEqual(SibionicsCaptureDecoder.parseLine("phone 25e2")?.direction, .phone)
        XCTAssertEqual(SibionicsCaptureDecoder.parseLine("sensor 25e2")?.direction, .sensor)
        XCTAssertEqual(SibionicsCaptureDecoder.parseLine("rx 25e2")?.direction, .sensor)
        XCTAssertEqual(SibionicsCaptureDecoder.parseLine("tx 25e2")?.direction, .phone)

        XCTAssertNil(SibionicsCaptureDecoder.parseLine(""), "blank")
        XCTAssertNil(SibionicsCaptureDecoder.parseLine("# a comment"), "comment")
        XCTAssertNil(SibionicsCaptureDecoder.parseLine("zzzz"), "not hex")
        XCTAssertNil(SibionicsCaptureDecoder.parseLine("25e"), "odd length")
    }

    func testWrongMACProducesNothingRatherThanGarbage() throws {
        let frame = try SibionicsCommand.authFrame(
            mac: Fixtures.mac, registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
        )
        let sealed = try sealed(frame)
        let wrong = try SibionicsCipher(mac: "01:02:03:04:05:06")
        // A wrong IV gives a wrong keystream, so the checksum cannot pass.
        XCTAssertNil(SibionicsCaptureDecoder.decode(sealed, direction: .phone, cipher: wrong))
    }
}
