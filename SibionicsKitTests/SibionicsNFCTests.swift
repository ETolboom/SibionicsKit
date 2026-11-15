@testable import SibionicsKit
import XCTest

final class SibionicsNFCTests: XCTestCase {
    private let sample = "GJ,GS3*-BEABMA,GNL,AAC25B18AAFZ,E2AFF9F01F19,PG291,HT"

    func testParsesTheDocumentedRecord() throws {
        let record = try XCTUnwrap(SibionicsNFCRecord(raw: sample))
        XCTAssertEqual(record.fields.count, 7)
        XCTAssertEqual(record.model, "GS3*-BEABMA")
        XCTAssertEqual(record.regionCode, "GNL")
        // The first field that is exactly 12 hex digits.
        XCTAssertEqual(record.mac, "E2:AF:F9:F0:1F:19")
        XCTAssertEqual(record.bleNameSuffix, "BEABMA")
    }

    func testChinaRegion() throws {
        let record = try XCTUnwrap(SibionicsNFCRecord(raw: "GJ,GS3*-XXXXXX,CN,AABBCCDDEEFF,112233445566"))
        XCTAssertEqual(record.regionCode, "CN")
        XCTAssertEqual(record.mac, "AABBCCDDEEFF".withMACSeparators)
    }

    func testRejectsNonRecords() {
        XCTAssertNil(SibionicsNFCRecord(raw: ""))
        XCTAssertNil(SibionicsNFCRecord(raw: "nonsense"))
        XCTAssertNil(SibionicsNFCRecord(raw: "a,b"))
    }

    func testNonHexFieldIsNotAMACCandidate() {
        XCTAssertNil(SibionicsNFCRecord.macCandidate(from: "AAC25B18AAFZ"), "Z is not hex")
        XCTAssertEqual(SibionicsNFCRecord.macCandidate(from: "aabbccddeeff"), "AA:BB:CC:DD:EE:FF")
    }

    func testDerivedMACIsUsableByTheCipher() throws {
        let record = try XCTUnwrap(SibionicsNFCRecord(raw: sample))
        let mac = try XCTUnwrap(record.mac)
        XCTAssertNoThrow(try SibionicsCipher(mac: mac))
    }
}

private extension String {
    var withMACSeparators: String {
        stride(from: 0, to: count, by: 2).map {
            let start = index(startIndex, offsetBy: $0)
            let end = index(start, offsetBy: 2)
            return String(self[start ..< end])
        }.joined(separator: ":")
    }
}
