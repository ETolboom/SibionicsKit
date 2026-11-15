@testable import SibionicsKit
import XCTest

/// The dump is a diagnostic, so the thing worth testing is that it reports the
/// truth about a payload even when the field parsing is wrong.
final class SibionicsNFCDumpTests: XCTestCase {
    /// Exactly what a real GS3 applicator reports (see `GS3 Activation.pklg`):
    /// app prefix, product serial, a one-digit code, a lot number. No MAC.
    private let recordString = "GJ,04ES126090500NA,6,10943L"

    /// An older/other tag variant, kept so a tag that *does* carry a MAC still
    /// parses.
    private let legacyRecordString = "GJ,GS3*-BEABMA,GNL,AAC25B18AAFZ,E2AFF9F01F19,PG291,HT"

    private func textPayload(_ text: String) -> SibionicsNFCDump.Payload {
        // NDEF text record: status byte (UTF-8, no language) + "en" + text.
        var payload = Data([0x02])
        payload.append(Data("en".utf8))
        payload.append(Data(text.utf8))
        return SibionicsNFCDump.Payload(typeNameFormat: "well-known", typeDescription: "T", payload: payload)
    }

    private func uriPayload(_ uri: String) -> SibionicsNFCDump.Payload {
        // 0x04 == "https://", then the rest of the URI.
        var payload = Data([0x04])
        payload.append(Data(uri.utf8))
        return SibionicsNFCDump.Payload(typeNameFormat: "well-known", typeDescription: "U", payload: payload)
    }

    // MARK: - Payload decoding

    func testTextRecordDecoding() {
        let payload = textPayload(recordString)
        XCTAssertEqual(payload.decoded, recordString)
    }

    func testURIRecordDecodingUsesThePrefixTable() {
        let payload = uriPayload("example.com/t?d=abc")
        XCTAssertEqual(payload.decoded, "https://example.com/t?d=abc")
    }

    func testBinaryPayloadIsNotClaimedAsText() {
        let payload = SibionicsNFCDump.Payload(
            typeNameFormat: "unknown", typeDescription: "application/octet-stream",
            payload: Data([0x00, 0x01, 0x02, 0xFF, 0xFE])
        )
        XCTAssertNil(payload.decoded)
        XCTAssertFalse(payload.summary.contains("nil"))
    }

    func testShortTextPayloadDoesNotCrash() {
        let payload = SibionicsNFCDump.Payload(
            typeNameFormat: "well-known", typeDescription: "T", payload: Data([0x02])
        )
        XCTAssertNil(payload.decoded, "language length runs past the payload")
    }

    // MARK: - Parsing

    /// The real tag: serial only, and the serial is what `F0 0E` reports.
    func testParsesTheRealApplicatorTag() {
        let dump = SibionicsNFCDump(
            tagType: "MIFARE unknown family (ISO14443)",
            identifier: Data([0x1D, 0x37, 0x0A, 0x5A, 0x20, 0x10, 0x80]),
            ndefStatus: "read/write",
            capacity: 137,
            payloads: [textPayload(recordString)]
        )
        XCTAssertEqual(dump.records.count, 1)
        let record = dump.bestRecord
        XCTAssertEqual(record?.appPrefix, "GJ")
        XCTAssertEqual(record?.serial, "04ES126090500NA")
        XCTAssertEqual(dump.parsedSerial, "04ES126090500NA")
        XCTAssertNil(record?.mac, "a GS3 tag carries no MAC")
        XCTAssertNil(record?.model)
        XCTAssertNil(record?.regionCode)
        XCTAssertNil(record?.bleNameSuffix, "no GS3 model field on this tag")
    }

    /// A tag variant that does carry one still parses.
    func testParsesALegacyTagCarryingAMAC() {
        let dump = SibionicsNFCDump(
            tagType: "ISO15693", ndefStatus: "read/write",
            payloads: [textPayload(legacyRecordString)]
        )
        XCTAssertEqual(dump.bestRecord?.mac, "E2:AF:F9:F0:1F:19")
        XCTAssertEqual(dump.bestRecord?.model, "GS3*-BEABMA")
        XCTAssertEqual(dump.bestRecord?.regionCode, "GNL")
        XCTAssertEqual(dump.bestRecord?.bleNameSuffix, "BEABMA")
        XCTAssertEqual(dump.bestRecord?.serial, "AAC25B18AAFZ", "the long alphanumeric field")
    }

    func testParsesARecordOutOfAURIPayload() {
        let dump = SibionicsNFCDump(
            tagType: "ISO15693", ndefStatus: "read/write",
            payloads: [uriPayload("example.com/p?" + recordString)]
        )
        XCTAssertEqual(dump.parsedSerial, "04ES126090500NA")
    }

    func testUnparseablePayloadIsStillDumped() {
        let dump = SibionicsNFCDump(
            tagType: "MIFARE Ultralight (ISO14443)",
            identifier: Data([0x01, 0x02]),
            ndefStatus: "read/write",
            capacity: 48,
            payloads: [textPayload("something else entirely")]
        )
        XCTAssertTrue(dump.records.isEmpty)
        XCTAssertNil(dump.parsedMAC)

        let text = dump.text
        XCTAssertTrue(text.contains("parsed record: none"), text)
        XCTAssertTrue(text.contains("something else entirely"), "the raw text must survive for diagnosis:\n\(text)")
    }

    func testEmptyTagDumpIsHonestRatherThanMisleading() {
        let dump = SibionicsNFCDump(tagType: "ISO7816 / ISO-DEP", ndefStatus: "not NDEF", payloads: [])
        XCTAssertNil(dump.parsedMAC)
        XCTAssertTrue(dump.text.contains("not NDEF"))
        XCTAssertTrue(dump.text.contains("payloads: 0"))
        XCTAssertTrue(dump.text.contains("uid:      (none)"))
    }

    // MARK: - Dump text

    func testDumpTextCarriesEverythingNeededToReproduce() {
        let dump = SibionicsNFCDump(
            tagType: "MIFARE Ultralight (ISO14443)",
            identifier: Data([0x04, 0xAB, 0xCD]),
            ndefStatus: "read/write",
            capacity: 137,
            payloads: [textPayload(recordString)]
        )
        let text = dump.text
        XCTAssertTrue(text.contains("04abcd"), "uid hex:\n\(text)")
        XCTAssertTrue(text.contains("capacity 137"), text)
        XCTAssertTrue(text.contains("well-known/T"), text)
        XCTAssertTrue(text.contains(recordString), text)
        XCTAssertTrue(text.contains("serial: 04ES126090500NA"), text)
        XCTAssertTrue(text.contains("(none — a GS3 tag carries no MAC)"), text)
        // The raw payload must be present so a wrong parse can be spotted.
        XCTAssertTrue(text.contains("raw:"), text)
    }

    func testDumpFlagsAMACThatIsNotSixBytes() {
        // A 12-character field with a non-hex character is not a MAC; the parser
        // should not choose it, and the dump says so when a chosen one is bad.
        let dump = SibionicsNFCDump(
            tagType: "ISO15693", ndefStatus: "read/write",
            payloads: [textPayload("GJ,GS3*-ABCDEF,GNL,ZZZZZZZZZZZZ,112233445566")]
        )
        XCTAssertEqual(dump.parsedMAC, "11:22:33:44:55:66")
    }
}
