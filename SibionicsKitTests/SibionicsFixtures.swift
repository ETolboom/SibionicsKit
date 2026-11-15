import Foundation
@testable import SibionicsKit

/// Real values, taken from a hardware capture of the official app activating a
/// fresh GS3 (`GS3 Activation.pklg`, iOS + PacketLogger, sensor
/// `SISENSING-GNL` / `GS3*-5EANLA`, software revision `1.1.6I_V3.4.0`).
///
/// Every ciphertext/plaintext pair below was observed on the wire, so these
/// tests fail if the driver's cipher, framing or field layout drifts away from
/// what the sensor actually does — which is a much stronger statement than
/// agreeing with our own encoder.
enum Fixtures {
    /// The sensor's serial number characteristic (`0x2A25`) is the MAC, in this
    /// order, and it appears byte-for-byte like this in the auth frame.
    static let mac = "68:7D:10:C7:C0:C2"
    static let macBytes = Data([0x68, 0x7D, 0x10, 0xC7, 0xC0, 0xC2])
    static let iv = Data([0x68, 0x7D, 0x10, 0xC7, 0xC0, 0xC2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])

    /// Confirmed against the capture: exactly the constant in
    /// `SibionicsRegistrationKey.gs3`.
    static let registrationKey = Data("THE544U0TYITE461".utf8)

    /// 8 bytes big-endian, then 4 zeros — the numeric account id layout.
    static let accountBytes = Data(hex: "1d720bee0350a34900000000")
    static let accountString = "2121771491330663241"

    /// `0x6AF905FB`.
    static let activationTimestamp: UInt32 = 1_794_704_891

    // MARK: - Captured frames

    static let authFramePlaintext = Data(
        hex:
        "25e200687d10c7c0c2544845353434553054594954453436311d720bee0350a34900000000c7"
    )
    static let authFrameCiphertext = Data(
        hex:
        "09e0bfbf77b27a036ba1bb3a56ab9e597e9912b8dac881aaa671612bf0cb2c9baff1fb72594a"
    )

    static let authAckPlaintext = Data(hex: "04e2010019")
    static let authAckCiphertext = Data(hex: "28e0bed713")

    static let activationPlaintext = Data(
        hex:
        "1235fb05f96a1d720bee0350a349000000008f"
    )
    static let activationCiphertext = Data(hex: "3e3744d2f3c8a0b1a21bf02fc0d6aa0c4ecdc4")
    /// `[len][0x35][status 01][00][activation time echoed][cksum]`.
    static let activationAckPlaintext = Data(hex: "09350100fb05f96a3c22")

    /// First live record, one minute after activation: during warmup the sensor
    /// reports the `0xFF01` "no result" sentinel.
    static let liveRecordPlaintext = Data(
        hex:
        "1732010100e42d4727bf2c01fffc2c0208d72a662b000087"
    )
    static let liveRecordCiphertext = Data(
        hex:
        "3b30bed60a4690848e4adf7e9c63860e461a6197a58db51b"
    )

    /// The sensor's "nothing left" history answer: a zero count in a two-byte
    /// payload, which is why a short packet must not be a parse error.
    static let emptyHistoryPlaintext = Data(hex: "04390005be")

    /// `AES-128-ECB(algorithmKey, 0^16)` — the masked algorithm-glucose field's
    /// key stream, from the vendor's algorithm key.
    static let algorithmGlucoseMaskBytes = Data(hex: "fc2c93d590c09eb22cac06f8cbab7578")

    /// The whole decrypted conversation on the FF30 service, in order.
    static let trace: [(direction: String, plaintext: String)] = [
        ("phone", "25e200687d10c7c0c2544845353434553054594954453436311d720bee0350a34900000000c7"),
        ("sensor", "04e2010019"),
        ("phone", "03f00ffe"),
        ("sensor", "04f00f00fd"),
        ("phone", "03f00eff"),
        ("sensor", "1cf00e01303445533132363039303530304e4100000000000000000093"),
        ("phone", "03f0010c"),
        ("sensor", "07f00146505945d4"),
        ("phone", "03f011fc"),
        ("sensor", "04f0113cbf"),
        ("phone", "1235fb05f96a1d720bee0350a349000000008f"),
        ("sensor", "09350100fb05f96a3c22"),
        ("phone", "03f00ffe"),
        ("sensor", "04f00f02fb"),
        ("phone", "063901000000c0"),
        ("sensor", "04390005be"),
        ("sensor", "1732010100e42d4727bf2c01fffc2c0208d72a662b000087"),
        ("sensor", "1732010200e52d4527bd2c01fffc2c0208da2a662b000086")
    ]

    // MARK: - Builders

    static func account() throws -> SibionicsAccountID {
        try SibionicsAccountID(bytes: accountBytes)
    }

    /// A plausible record: 5.7 mmol/L, current 1234, trend 3.
    static func recordData(
        glucoseRaw: UInt16 = 57,
        current: UInt16 = 1234,
        presentCState: Bool = false
    ) -> Data {
        var data = Data(count: 16)
        func put16(_ value: UInt16, _ offset: Int) {
            data[offset] = UInt8(value & 0xFF)
            data[offset + 1] = UInt8(value >> 8)
        }
        put16(2650, 0)
        put16(7, 2)
        put16(current, 4)
        put16(glucoseRaw, 6)
        put16(0x2CFC ^ 60, 8)
        data[10] = (5 << 4) | (presentCState ? 0x08 : 0) | 0x03
        data[11] = 0b0000_0110
        put16(1500, 12)
        put16(900, 14)
        return data
    }

    static func glucosePayload(
        cmd _: UInt8,
        startIndex: UInt16,
        records: [Data],
        tail: UInt16? = nil
    ) -> Data {
        var payload = Data([UInt8(clamping: records.count)])
        payload.append(UInt8(startIndex & 0xFF))
        payload.append(UInt8(startIndex >> 8))
        for record in records { payload.append(record) }
        if let tail {
            payload.append(UInt8(tail & 0xFF))
            payload.append(UInt8(tail >> 8))
        }
        return payload
    }

    /// `F0 03` reply: `startover u16 | activation u32 | current u32 | last u32 | lastIndex u16`.
    static func deviceTimePayload(
        startover: UInt16 = 0,
        activation: UInt32,
        current: UInt32,
        last: UInt32,
        lastIndex: UInt16
    ) -> Data {
        var payload = Data()
        payload.append(contentsOf: le16(startover))
        payload.append(contentsOf: le32(activation))
        payload.append(contentsOf: le32(current))
        payload.append(contentsOf: le32(last))
        payload.append(contentsOf: le16(lastIndex))
        return payload
    }

    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }
}

extension Data {
    init(hex: String) {
        let clean = hex.filter(\.isHexDigit)
        var bytes = [UInt8]()
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            bytes.append(UInt8(clean[index ..< next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
