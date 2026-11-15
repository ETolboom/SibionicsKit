@testable import SibionicsKit
import XCTest

final class SibionicsCipherTests: XCTestCase {
    func testTransportKeyIsTheRecoveredConstant() {
        XCTAssertEqual(
            SibionicsCipher.transportKey.hexString,
            "01380b9a005b025dcd9ec3990937aae8"
        )
    }

    func testIVIsTheMACFollowedByTenZeros() throws {
        let cipher = try SibionicsCipher(mac: Fixtures.mac)
        XCTAssertEqual(cipher.iv.hexString, "687d10c7c0c200000000000000000000")
        XCTAssertEqual(cipher.iv.count, 16)
    }

    func testMACParsingAcceptsAnySeparators() {
        for style in [
            "68:7D:10:C7:C0:C2", "687d10c7c0c2", "68-7D-10-C7-C0-C2", "687D.10C7.C0C2"
        ] {
            XCTAssertEqual(try? SibionicsCipher.macBytes(style), Fixtures.macBytes, style)
        }
        XCTAssertThrowsError(try SibionicsCipher.macBytes("AA:BB:CC"))
        XCTAssertThrowsError(try SibionicsCipher.macBytes(""))
    }

    /// The expected ciphertext is from a hardware capture, so this pins the
    /// cipher to what the sensor actually does rather than to our own encoder.
    func testOFBMatchesCapturedHandshake() throws {
        let cipher = try SibionicsCipher(mac: Fixtures.mac)
        let sealed = try cipher.apply(Fixtures.authFramePlaintext)
        XCTAssertEqual(sealed, Fixtures.authFrameCiphertext)
        XCTAssertEqual(try cipher.apply(sealed), Fixtures.authFramePlaintext, "OFB must round-trip")
    }

    /// The vendor restarts the keystream for every frame, so identical
    /// plaintexts on one connection produce identical ciphertexts. This is a
    /// property of the protocol the driver must not "fix": a peer that expects
    /// a fresh IV will not interoperate.
    func testKeystreamRestartsPerFrame() throws {
        let cipher = try SibionicsCipher(mac: Fixtures.mac)
        let first = try cipher.apply(Fixtures.authFramePlaintext)
        let second = try cipher.apply(Fixtures.authFramePlaintext)
        XCTAssertEqual(first, second)
    }

    func testPartialFinalBlock() throws {
        let cipher = try SibionicsCipher(mac: Fixtures.mac)
        let payload = Data((0 ..< 19).map { UInt8($0) })
        let sealed = try cipher.apply(payload)
        XCTAssertEqual(sealed.count, payload.count)
        XCTAssertEqual(try cipher.apply(sealed), payload)
        XCTAssertNotEqual(sealed, payload)
    }

    func testEmptyInputIsIdentity() throws {
        let cipher = try SibionicsCipher(mac: Fixtures.mac)
        XCTAssertEqual(try cipher.apply(Data()), Data())
    }

    func testAlgorithmGlucoseMaskMatchesOpenSSL() {
        XCTAssertEqual(
            SibionicsRecord.algorithmGlucoseMask,
            UInt16(Fixtures.algorithmGlucoseMaskBytes[0])
                | (UInt16(Fixtures.algorithmGlucoseMaskBytes[1]) << 8)
        )
        XCTAssertEqual(SibionicsRecord.algorithmGlucoseMask, 0x2CFC)
    }
}
