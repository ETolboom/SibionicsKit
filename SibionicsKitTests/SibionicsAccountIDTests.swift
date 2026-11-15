import CryptoKit
@testable import SibionicsKit
import XCTest

final class SibionicsAccountIDTests: XCTestCase {
    func testNumericIDIsEightByteBigEndianPlusFourZeros() throws {
        XCTAssertEqual(try SibionicsAccountID("1234").bytes.hexString, "00000000000004d200000000")
        XCTAssertEqual(try SibionicsAccountID("0").bytes.hexString, "000000000000000000000000")
        XCTAssertEqual(
            try SibionicsAccountID("18446744073709551615").bytes.hexString,
            "ffffffffffffffff00000000"
        )
    }

    func testWhitespaceIsTrimmed() throws {
        XCTAssertEqual(try SibionicsAccountID("  1234  ").bytes, try SibionicsAccountID("1234").bytes)
    }

    /// Non-numeric ids take the SHA-256 path in the official app. Not exercised
    /// by the traces this driver was built from, but cheaper to support than to
    /// discover in the field.
    func testNonNumericIDUsesSHA256Prefix() throws {
        let id = "user-abc"
        let expected = Data(SHA256.hash(data: Data(id.utf8)).prefix(12))
        XCTAssertEqual(try SibionicsAccountID(id).bytes, expected)
    }

    /// All-digit but too big for UInt64: the official app's
    /// `sib_parseUnsignedInt64FromDigitsOnlyString:` fails and it errors out
    /// rather than hashing, so this is an error, not a silent fallback.
    func testAllDigitIdentifiersTooBigForUInt64AreRejected() {
        XCTAssertThrowsError(try SibionicsAccountID("999999999999999999999999"))
    }

    func testEmptyIsRejected() {
        XCTAssertThrowsError(try SibionicsAccountID(""))
        XCTAssertThrowsError(try SibionicsAccountID("   "))
    }

    func testWrongByteCountIsRejected() {
        XCTAssertThrowsError(try SibionicsAccountID(bytes: Data(repeating: 0, count: 11)))
        XCTAssertThrowsError(try SibionicsAccountID(bytes: Data(repeating: 0, count: 13)))
    }

    func testGeneratedIdentityRoundTripsAndLooksLikeAServerId() throws {
        let generated = SibionicsAccountID.generated()
        // Decimal form parses back to exactly the same 12 wire bytes.
        XCTAssertEqual(try SibionicsAccountID(generated.string).bytes, generated.id.bytes)
        // 8 bytes big-endian, then 4 zeros — the layout server ids use.
        XCTAssertEqual(generated.id.bytes.count, 12)
        XCTAssertEqual(Array(generated.id.bytes.suffix(4)), [0, 0, 0, 0])
        // All digits, so the numeric encoding path is the one taken.
        XCTAssertTrue(generated.string.allSatisfy(\.isNumber))
        // No leading zero, which would otherwise be a different string for the
        // same bytes.
        XCTAssertNotEqual(generated.string.first, "0")
        // Full 64-bit range: not a short, guessable value.
        XCTAssertGreaterThanOrEqual(UInt64(generated.string) ?? 0, 1_000_000_000_000_000)
    }

    func testGeneratedIdentitiesDiffer() {
        let values = Set((0 ..< 32).map { _ in SibionicsAccountID.generated().string })
        XCTAssertEqual(values.count, 32)
    }

    func testDescriptionRedacts() throws {
        let id = try SibionicsAccountID("1234")
        XCTAssertFalse(id.description.contains("1234"))
    }
}
