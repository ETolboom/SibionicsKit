@testable import SibionicsKit
import XCTest

final class SibionicsCommandTests: XCTestCase {
    func testActivationFrameLayout() throws {
        let frame = try SibionicsCommand.activateBindInFrame(
            activationTime: 0x6A1B_2C3D, accountID: try Fixtures.account()
        )
        var expected = Data([0x12, 0x35, 0x3D, 0x2C, 0x1B, 0x6A])
        expected.append(Fixtures.accountBytes)
        expected.append(UInt8(truncatingIfNeeded: 0 &- expected.reduce(UInt16(0)) { ($0 &+ UInt16($1)) }))

        XCTAssertEqual(frame.encoded, expected)
        XCTAssertEqual(frame.encoded.count, 19)
        XCTAssertEqual(frame.encoded[0], 0x12)
        XCTAssertEqual(frame.encoded[1], 0x35)
        XCTAssertEqual(frame.cmd, SibionicsCommand.activateBindIn)
    }

    func testActivationTimeIsLittleEndian() throws {
        let frame = try SibionicsCommand.activateBindInFrame(
            activationTime: 0x0102_0304, accountID: try Fixtures.account()
        )
        XCTAssertEqual(Array(frame.encoded[2 ..< 6]), [0x04, 0x03, 0x02, 0x01])
    }

    /// The official app builds `F0` queries whose last byte works out to
    /// `0x0D - sub`; the generic encoder must reproduce that exactly.
    func testInfoQueriesMatchTheAppsEncodedByte() {
        let subs: [UInt8] = [0x01, 0x03, 0x0E, 0x0F, 0x11]
        for sub in subs {
            let frame = SibionicsCommand.infoQueryFrame(sub)
            let expectedLast = UInt8(truncatingIfNeeded: 0x0D &- Int32(sub))
            XCTAssertEqual(frame.encoded.hexString, String(format: "03f0%02x%02x", sub, expectedLast))
        }
    }

    func testHistoryRequest() {
        // Byte-for-byte what the official app was captured sending for
        // `first=1`: `P 06 39 01 00 00 00 c0`. The second slot is hard-coded 0
        // ("to the end"); GS3 V3 answers a bounded value with `01 00` instead
        // of records, so 0 is the only form that works.
        XCTAssertEqual(
            SibionicsCommand.historyRequestFrame(from: 1).encoded.hexString,
            "063901000000c0"
        )
        XCTAssertEqual(
            SibionicsCommand.historyRequestFrame(from: 0).encoded.hexString,
            "063900000000c1"
        )
        XCTAssertEqual(SibionicsCommand.historyRequestFrame(from: 5, to: 9).encoded[2 ..< 6], Data([5, 0, 9, 0]))
    }

    func testShortRegistrationKeyIsRejected() {
        XCTAssertThrowsError(try SibionicsCommand.authFrame(
            mac: Fixtures.mac,
            registrationKey: Data(repeating: 0, count: 15),
            accountID: try Fixtures.account()
        ))
    }

    func testOpcodesMatchTheRecoveredTable() {
        XCTAssertEqual(SibionicsCommand.auth, 0xE2)
        XCTAssertEqual(SibionicsCommand.activateBindIn, 0x35)
        XCTAssertEqual(SibionicsCommand.infoQuery, 0xF0)
        XCTAssertEqual(SibionicsCommand.historyRequest, 0x39)
        XCTAssertEqual(SibionicsCommand.liveRecord, 0x32)
        XCTAssertEqual(SibionicsCommand.cachedRecord, 0x36)
        XCTAssertEqual(SibionicsCommand.deactivate, 0xE0)
    }
}
