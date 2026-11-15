import Foundation

/// The plaintext GS3 frame:
///
///     [len] [cmd] [payload …] [checksum]
///
/// * `len == size - 1`, i.e. `payload.count + 2`.
/// * `checksum` is the two's complement of the byte sum, so every frame sums
///   to `0 mod 256`. Eight bits with no key material: it detects corruption,
///   not tampering.
/// * `len` is a single byte, so a frame is **at most 256 bytes**. That is a hard
///   ceiling on a history packet: 15 records of 16 bytes at most. Longer ranges
///   therefore always need several round trips, which is why backfill re-requests.
///
/// Recovering the frame layout this way reproduces the official app's frames
/// byte-for-byte, including the `0x0D - sub` info-query checksum, which is a
/// good sanity check that the model is right.
public struct SibionicsFrame: Equatable, Sendable {
    /// The 1-byte length field allows `size - 1 <= 255`.
    public static let maxSize = 256
    /// Largest payload a frame can carry.
    public static let maxPayload = maxSize - 3
    /// Most 16-byte records a `0x32`/`0x39` packet can hold: 8 + 16n <= 256.
    public static let maxRecordsPerPacket = (maxSize - 8) / 16
    public static let headerWidth = 2
    public static let checksumWidth = 1

    public let cmd: UInt8
    public let payload: Data

    public init(cmd: UInt8, payload: Data = Data()) {
        self.cmd = cmd
        self.payload = payload
    }

    public var size: Int { payload.count + Self.headerWidth + Self.checksumWidth }

    /// `len` field: one less than the wire size.
    public var lengthField: UInt8 { UInt8(size - 1) }

    /// Checksum over `[len][cmd][payload]`.
    public var checksum: UInt8 {
        var sum = UInt16(lengthField) + UInt16(cmd)
        for byte in payload { sum += UInt16(byte) }
        return UInt8(truncatingIfNeeded: 0 &- sum)
    }

    public var encoded: Data {
        var out = Data(capacity: size)
        out.append(lengthField)
        out.append(cmd)
        out.append(payload)
        out.append(checksum)
        return out
    }

    public enum DecodeError: Error, Equatable, CustomStringConvertible {
        case tooShort(Int)
        case badLength(declared: Int, actual: Int)
        case badChecksum(expected: UInt8, actual: UInt8)
        case tooLarge(Int)

        public var description: String {
            switch self {
            case let .tooShort(n): return "frame: \(n) bytes is too short to hold a frame"
            case let .badLength(declared, actual):
                return "frame: length byte says \(declared + 1) bytes, buffer has \(actual)"
            case let .badChecksum(expected, actual):
                return String(format: "frame: checksum mismatch (expected 0x%02x, got 0x%02x)", actual, expected)
            case let .tooLarge(n): return "frame: \(n) bytes exceeds the \(SibionicsFrame.maxSize)-byte limit"
            }
        }
    }

    /// Decodes a frame whose *checksum is included*. A notify value is
    /// block-padded by the sensor, so callers trim to `Int(bytes[0]) + 1`
    /// first; this initialiser accepts trailing padding only when the caller
    /// asks for it (`allowTrailingPadding`).
    public init(decoding bytes: Data, allowTrailingPadding: Bool = true) throws {
        guard bytes.count >= 3 else { throw DecodeError.tooShort(bytes.count) }
        let declaredSize = Int(bytes[bytes.startIndex]) + 1
        if declaredSize > Self.maxSize { throw DecodeError.tooLarge(declaredSize) }
        guard allowTrailingPadding ? declaredSize <= bytes.count : declaredSize == bytes.count else {
            throw DecodeError.badLength(declared: Int(bytes[bytes.startIndex]), actual: bytes.count)
        }
        guard declaredSize >= 3 else { throw DecodeError.tooShort(declaredSize) }

        let start = bytes.startIndex
        let frameBytes = bytes[start ..< start + declaredSize]

        var sum: UInt16 = 0
        for byte in frameBytes { sum += UInt16(byte) }
        let actual = UInt8(truncatingIfNeeded: sum)
        guard actual == 0 else {
            throw DecodeError.badChecksum(expected: 0, actual: actual)
        }

        cmd = frameBytes[frameBytes.startIndex + 1]
        payload = Data(frameBytes.dropFirst(2).dropLast(1))
    }

    /// The shortest buffer that could carry this frame, given a notify value
    /// that may be block-padded.
    public static func trimmedSize(of bytes: Data) -> Int? {
        guard let first = bytes.first else { return nil }
        let declared = Int(first) + 1
        guard declared >= 3, declared <= bytes.count else { return nil }
        return declared
    }
}
