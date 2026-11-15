import Foundation

/// GS3 V3 opcodes and frame builders.
///
/// The opcodes are the ones the official app's `SibBleCmdMapper` maps its
/// internal `cmdType` enum onto; they cross-check against an independent
/// implementation (Juggluco) on the V2 side and against the V3 auth and history
/// frames, so the numbering is solid even where the semantics of an individual
/// opcode are still a guess.
public enum SibionicsCommand {
    // MARK: Opcodes

    /// V3 authentication / bind check. `SibBleAuthCheckIDCommand`.
    public static let auth: UInt8 = 0xE2
    /// V3 activation + account bind. `SibBleActiveBindInCommand`.
    /// Recovered from the iOS app; not previously documented, see
    /// `GS3-activation-findings.md`.
    public static let activateBindIn: UInt8 = 0x35
    /// Info query, `F0 <sub>`.
    public static let infoQuery: UInt8 = 0xF0
    /// History request.
    public static let historyRequest: UInt8 = 0x39
    /// Live record push (sensor → phone).
    public static let liveRecord: UInt8 = 0x32
    /// Cached latest record (sensor → phone).
    public static let cachedRecord: UInt8 = 0x36
    /// History record push (sensor → phone).
    public static let historyRecord: UInt8 = 0x39
    /// Deactivate. Payload not modelled: destructive and not needed to read.
    public static let deactivate: UInt8 = 0xE0

    /// Opaque "startover" counter carried by the `0xF0 0x03` reply.
    public static let infoDeviceTime: UInt8 = 0x03
    public static let infoStatus: UInt8 = 0x0F
    public static let infoExtended: UInt8 = 0x0E
    public static let infoExtended2: UInt8 = 0x11
    public static let infoVersion: UInt8 = 0x01
    public static let infoReset: UInt8 = 0x07

    // MARK: Builders

    /// `25 E2 00 | mac reversed (6) | registration key (16) | account id (12) | cksum`
    ///
    /// The 38-byte V3 auth frame. `pad` is the `0x00` the app puts immediately
    /// after the opcode; it is a constant in every observed trace.
    public static func authFrame(
        mac: String,
        registrationKey: Data,
        accountID: SibionicsAccountID,
        pad: UInt8 = 0x00
    ) throws -> SibionicsFrame {
        guard registrationKey.count == 16 else {
            throw EncodingError.badRegistrationKeyLength(registrationKey.count)
        }
        var payload = Data(capacity: 1 + 6 + 16 + SibionicsAccountID.byteCount)
        payload.append(pad)
        payload.append(try SibionicsCipher.macBytes(mac))
        payload.append(registrationKey)
        payload.append(accountID.bytes)
        return SibionicsFrame(cmd: auth, payload: payload)
    }

    /// `12 35 <activation time u32 LE> <account id (12)> <cksum>`
    ///
    /// The V3 activation command. `timestamp` is unix seconds and becomes the
    /// sensor's clock origin: every record index is relative to it and there is
    /// no V3 command to correct it afterwards.
    public static func activateBindInFrame(
        activationTime: UInt32,
        accountID: SibionicsAccountID
    ) throws -> SibionicsFrame {
        var payload = Data(capacity: 4 + SibionicsAccountID.byteCount)
        payload.append(contentsOf: withUnsafeBytes(of: activationTime.littleEndian) { Array($0) })
        payload.append(accountID.bytes)
        return SibionicsFrame(cmd: activateBindIn, payload: payload)
    }

    /// `03 F0 <sub> <0x0D - sub>`. The fourth byte is just the frame checksum,
    /// so the general encoder produces it.
    public static func infoQueryFrame(_ sub: UInt8) -> SibionicsFrame {
        SibionicsFrame(cmd: infoQuery, payload: Data([sub]))
    }

    /// `06 39 <first u16 LE> <last u16 LE> <cksum>`.
    ///
    /// `last = 0` means "to the end". The capture of the official app shows it
    /// hard-coding `0` here (`39 01 00 00 00 c0`), and a *bounded* `last` is
    /// answered on GS3 V3 hardware with a two-byte `01 00` payload instead of
    /// records — so "to the end" is the only form the sensor serves. Juggluco's
    /// `0xFFFF` is not equivalent.
    public static func historyRequestFrame(from first: UInt16, to last: UInt16 = 0) -> SibionicsFrame {
        var payload = Data(capacity: 4)
        payload.append(UInt8(first & 0xFF))
        payload.append(UInt8(first >> 8))
        payload.append(UInt8(last & 0xFF))
        payload.append(UInt8(last >> 8))
        return SibionicsFrame(cmd: historyRequest, payload: payload)
    }

    // MARK: Errors

    public enum EncodingError: Error, CustomStringConvertible {
        case badRegistrationKeyLength(Int)

        public var description: String {
            switch self {
            case let .badRegistrationKeyLength(n):
                return "auth frame: registration key is \(n) bytes, expected 16"
            }
        }
    }
}
