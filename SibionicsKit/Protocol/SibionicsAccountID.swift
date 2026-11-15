import CryptoKit
import Foundation

/// The 12 bytes that identify the user inside a V3 auth or activation frame.
///
/// The official app (`+[SibUserIdCodec encodeUserId:error:]`) branches on the
/// account id string:
///
/// * all decimal digits → 8-byte big-endian `UInt64`, then 4 zero bytes;
/// * anything else → the first 12 bytes of `SHA256(utf8)`.
///
/// This is the *only* per-user secret in the V3 protocol. There is no key
/// exchange and no signature: the sensor compares these bytes against the
/// account it was bound to, and nothing else proves anything. Treat this type
/// as sensitive and never log it.
public struct SibionicsAccountID: Equatable, Sendable, CustomStringConvertible {
    public static let byteCount = 12

    /// The 12 wire bytes. Never log these.
    public let bytes: Data

    public enum EncodingError: Error, CustomStringConvertible {
        case empty
        case tooLarge(String)
        case badLength(Int)

        public var description: String {
            switch self {
            case .empty:
                return "account id is empty"
            case let .tooLarge(value):
                return "account id \"\(value)\" does not fit in a UInt64"
            case let .badLength(n):
                return "account id must be \(SibionicsAccountID.byteCount) bytes, got \(n)"
            }
        }
    }

    public init(bytes: Data) throws {
        guard bytes.count == Self.byteCount else { throw EncodingError.badLength(bytes.count) }
        self.bytes = bytes
    }

    /// No-validation initialiser, for values this type produced itself.
    private init(unchecked bytes: Data) { self.bytes = bytes }

    /// A locally generated identity, for sensors this driver activates itself.
    ///
    /// V3 has no separate bind step: the `0x35` activation frame carries the
    /// account id, so **that write is the binding**. A sensor still in its
    /// factory state therefore takes whatever it is first given, and if we
    /// choose the value we already know it — no login, no server, no per-user
    /// secret to fetch.
    ///
    /// The value is a full-range `UInt64` rendered as decimal, which keeps the
    /// wire form identical to a server-assigned id (8 bytes big-endian, then 4
    /// zeros). Choosing the range matters for a second reason: this really is
    /// the key that stops anyone else in BLE range from reading the sensor, so
    /// it must not be short or guessable.
    ///
    /// This cannot work for a sensor that is already bound — that one only
    /// answers the account id it was activated with.
    public struct Generated {
        public let id: SibionicsAccountID
        /// The decimal form, which is what gets persisted.
        public let string: String
    }

    public static func generated() -> Generated {
        var value = UInt64.random(in: 1 ... UInt64.max)
        // A 16-digit value always has the same wire form as any other numeric
        // id, but avoid a leading-zero string that would parse differently.
        if value < 1_000_000_000_000_000 { value &+= 1_000_000_000_000_000 }
        return Generated(id: SibionicsAccountID(unchecked: bigEndian12(value)), string: String(value))
    }

    /// 8 bytes big-endian, then 4 zeros — the layout the server-assigned ids
    /// use, so the sensor sees a shape it has seen before.
    static func bigEndian12(_ value: UInt64) -> Data {
        var out = Data(capacity: byteCount)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
        out.append(Data(repeating: 0, count: 4))
        return out
    }

    /// Encodes the account id string exactly the way the official app does.
    public init(_ userID: String) throws {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EncodingError.empty }
        try self.init(bytes: Self.encode(trimmed))
    }

    public static func encode(_ userID: String) throws -> Data {
        if !userID.isEmpty, userID.allSatisfy(\.isNumber) {
            guard let value = UInt64(userID) else { throw EncodingError.tooLarge(userID) }
            return bigEndian12(value)
        }
        // Non-numeric ids (some regions issue UUID-ish or prefixed ids) take
        // the SHA-256 path. Not exercised by the traces this driver was built
        // from; if auth starts failing on a non-numeric account, suspect this.
        return Data(SHA256.hash(data: Data(userID.utf8)).prefix(byteCount))
    }

    /// Redacted form, safe for logs.
    public var description: String { "account id <redacted, \(bytes.count) B>" }
}
