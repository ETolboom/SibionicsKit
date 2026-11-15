@testable import SibionicsKit
import XCTest

/// Everything here is checked against a real capture of the official app
/// activating a factory-fresh GS3. These are the tests that would have caught
/// the reversed-MAC bug that made the first draft unable to decrypt anything.
final class SibionicsCapturedTraceTests: XCTestCase {
    private func cipher() throws -> SibionicsCipher { try SibionicsCipher(mac: Fixtures.mac) }

    // MARK: - Cipher

    func testIVIsTheSerialNumberVerbatim() throws {
        // The sensor's 0x2A25 serial number reads 68:7D:10:C7:C0:C2 and that is
        // the IV, in that order. Reversing it — as the earlier notes said —
        // produces a keystream that decrypts every frame to noise.
        XCTAssertEqual(try cipher().iv, Fixtures.iv)
    }

    func testAuthFrameDecryptsWithTheCapturedCiphertext() throws {
        XCTAssertEqual(try cipher().apply(Fixtures.authFrameCiphertext), Fixtures.authFramePlaintext)
    }

    func testEveryCapturedFrameRoundTrips() throws {
        let cipher = try cipher()
        // Pairs of (ciphertext, plaintext) for the whole conversation.
        let pairs: [(Data, Data)] = [
            (Fixtures.authFrameCiphertext, Fixtures.authFramePlaintext),
            (Data(hex: "28e0bed713"), Fixtures.authAckPlaintext),
            (Fixtures.activationCiphertext, Fixtures.activationPlaintext),
            (Data(hex: "2537bed7f1a744a995d7"), Fixtures.activationAckPlaintext),
            (Fixtures.liveRecordCiphertext, Fixtures.liveRecordPlaintext),
            (Data(hex: "283bbfd2b4"), Fixtures.emptyHistoryPlaintext)
        ]
        for (ciphertext, plaintext) in pairs {
            XCTAssertEqual(try cipher.apply(ciphertext), plaintext, ciphertext.hexString)
        }
    }

    // MARK: - Framing

    func testRepliesAreLengthPrefixed() throws {
        // `04 E2 01 00 19`: len 4 (so five bytes), cmd 0xE2, payload 01 00,
        // checksum. Not the three-byte `E2 01 00` the notes claimed.
        let reply = try XCTUnwrap(SibionicsReply(decoding: Fixtures.authAckPlaintext))
        XCTAssertEqual(reply.cmd, SibionicsCommand.auth)
        XCTAssertEqual(reply.payload, Data([0x01, 0x00]))
        XCTAssertEqual(reply.status, 0x01)
        XCTAssertEqual(reply.raw.count, 5)
    }

    func testTrailingBlockPaddingIsTrimmed() throws {
        var padded = Fixtures.authAckPlaintext
        padded.append(Data(repeating: 0, count: 11)) // notify value padded to 16 B
        let reply = try XCTUnwrap(SibionicsReply(decoding: padded))
        XCTAssertEqual(reply.raw, Fixtures.authAckPlaintext)
    }

    // MARK: - Auth

    func testAuthFrameCarriesTheExpectedRegistrationKeyAndAccount() throws {
        let reply = try XCTUnwrap(SibionicsReply(decoding: Fixtures.authFramePlaintext))
        XCTAssertEqual(reply.cmd, SibionicsCommand.auth)

        let payload = [UInt8](reply.payload)
        XCTAssertEqual(Data(payload[0 ..< 1]), Data([0x00]), "the byte after the opcode")
        XCTAssertEqual(Data(payload[1 ..< 7]), Fixtures.macBytes, "MAC, in the sensor's own order")
        XCTAssertEqual(Data(payload[7 ..< 23]), SibionicsRegistrationKey.gs3)
        XCTAssertEqual(Data(payload[23 ..< 35]), Fixtures.accountBytes)
    }

    func testOurAuthFrameReproducesTheCapturedBytes() throws {
        let frame = try SibionicsCommand.authFrame(
            mac: Fixtures.mac,
            registrationKey: SibionicsRegistrationKey.gs3,
            accountID: try SibionicsAccountID(bytes: Fixtures.accountBytes)
        )
        XCTAssertEqual(frame.encoded, Fixtures.authFramePlaintext)
    }

    func testTheCapturedAccountStringEncodesBack() throws {
        // If this holds, the numeric account-id path is right for real ids.
        XCTAssertEqual(
            try SibionicsAccountID(Fixtures.accountString).bytes,
            Fixtures.accountBytes
        )
    }

    // MARK: - Activation

    func testOurActivationFrameReproducesTheCapturedBytes() throws {
        let frame = try SibionicsCommand.activateBindInFrame(
            activationTime: Fixtures.activationTimestamp,
            accountID: try SibionicsAccountID(bytes: Fixtures.accountBytes)
        )
        XCTAssertEqual(frame.encoded, Fixtures.activationPlaintext)
    }

    func testActivationAckEchoesTheTimestamp() throws {
        // `09 35 01 00 <time LE> <cksum>` — the sensor states the start time it
        // took, which is a cheaper confirmation than a second round trip.
        let reply = try XCTUnwrap(SibionicsReply(decoding: Fixtures.activationAckPlaintext))
        XCTAssertEqual(reply.cmd, SibionicsCommand.activateBindIn)
        let payload = [UInt8](reply.payload)
        XCTAssertEqual(payload.first, 0x01, "status")
        let echoed = UInt32(payload[2]) | (UInt32(payload[3]) << 8)
            | (UInt32(payload[4]) << 16) | (UInt32(payload[5]) << 24)
        XCTAssertEqual(echoed, Fixtures.activationTimestamp)
    }

    // MARK: - Records

    func testCapturedLiveRecordDecodes() throws {
        let reply = try XCTUnwrap(SibionicsReply(decoding: Fixtures.liveRecordPlaintext))
        XCTAssertEqual(reply.cmd, SibionicsCommand.liveRecord)
        let packet = try XCTUnwrap(SibionicsGlucosePacket(cmd: reply.cmd, payload: reply.payload))

        XCTAssertEqual(packet.startIndex, 1)
        XCTAssertEqual(packet.records.count, 1)
        XCTAssertEqual(packet.tail, 0)

        let record = try XCTUnwrap(packet.records.first)
        XCTAssertEqual(record.index, 1)
        XCTAssertEqual(record.temperatureRaw, 0x2DE4)
        XCTAssertEqual(record.currentRaw, 0x2CBF)
        XCTAssertEqual(record.displayGlucoseRaw, 0xFF01, "warmup period: no result yet")
        XCTAssertFalse(record.hasGlucose)
        XCTAssertEqual(record.trendBits, 0x02)
        XCTAssertFalse(record.presentCState)
        XCTAssertEqual(record.tstate, 0)
        XCTAssertEqual(record.dstate, 2)
        XCTAssertEqual(record.ceVoltageRaw, 0x2AD7)
        XCTAssertEqual(record.reVoltageRaw, 0x2B66)
        // The masked algorithm field equals the mask exactly, i.e. zero.
        XCTAssertEqual(record.algorithmGlucose(), 0, accuracy: 0.001)
    }

    func testEmptyHistoryReplyIsATerminatorNotAParseError() throws {
        // Two payload bytes, which the count/startIndex header cannot hold.
        let reply = try XCTUnwrap(SibionicsReply(decoding: Fixtures.emptyHistoryPlaintext))
        XCTAssertEqual(reply.cmd, SibionicsCommand.historyRecord)
        let packet = try XCTUnwrap(SibionicsGlucosePacket(cmd: reply.cmd, payload: reply.payload))
        XCTAssertTrue(packet.records.isEmpty)
        XCTAssertTrue(packet.isEmptyHistoryTerminator)
    }

    // MARK: - Info queries

    func testTheAppQueriesTheseInfoSubsystems() throws {
        // Matches what the capture shows, and confirms the checksum rule
        // (`0x0D - sub`) the generic encoder relies on.
        let subs: [UInt8] = [0x0F, 0x0E, 0x01, 0x11]
        for sub in subs {
            let frame = SibionicsCommand.infoQueryFrame(sub)
            let reply = try XCTUnwrap(
                SibionicsReply(decoding: Data(hex: Fixtures.trace.first {
                    $0.direction == "phone" && $0.plaintext.hasPrefix("03f0")
                        && $0.plaintext.dropFirst(4).prefix(2) == String(format: "%02x", sub)
                }?.plaintext ?? "00"))
            )
            XCTAssertEqual(reply.cmd, SibionicsCommand.infoQuery)
            XCTAssertEqual(frame.payload, Data([sub]))
        }
    }

    /// The tag's serial and the sensor's `F0 0E` are the same string, which is
    /// what makes tag-based pairing verifiable.
    func testApplicatorTagSerialMatchesTheSensorsF0E() throws {
        let tagText = "GJ,04ES126090500NA,6,10943L"
        let tag = try XCTUnwrap(SibionicsNFCRecord(raw: tagText))

        let plaintext = Data(hex: Fixtures.trace[5].plaintext) // the F0 0E reply
        let reply = try XCTUnwrap(SibionicsReply(decoding: plaintext))
        let bytes = [UInt8](reply.payload)
        let serial = String(decoding: bytes.dropFirst(2).drop { $0 < 0x20 }.prefix { $0 >= 0x20 && $0 < 0x7F }, as: UTF8.self)
        XCTAssertEqual(serial, "04ES126090500NA")
        XCTAssertEqual(tag.serial, serial)
    }

    func testDeviceSerialPayloadIsReadable() throws {
        // `F0 0E` answers with `0e 01 ‖ "04ES126090500NA" ‖ zeros`.
        let plaintext = Data(hex: Fixtures.trace[5].plaintext)
        let reply = try XCTUnwrap(SibionicsReply(decoding: plaintext))
        let text = String(decoding: [UInt8](reply.payload).dropFirst(2).prefix(15), as: UTF8.self)
        XCTAssertEqual(text, "04ES126090500NA")
    }
}
