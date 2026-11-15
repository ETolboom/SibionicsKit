import Foundation

/// The GS3 V3 transport wrapper: AES-128-OFB, static key, IV derived from the
/// sensor's MAC, restarted for every frame.
///
/// Everything here is a constant of the vendor protocol recovered from the
/// official app; none of it is negotiated and none of it is a secret from the
/// sensor's point of view. It provides *no* authentication: the only
/// per-installation secret in V3 is the account id inside the auth frame.
public struct SibionicsCipher: Sendable {
    /// Recovered from `-[SibProtocolV3 ...]`'s key global; verified against a
    /// real trace (it is the same key Juggluco uses).
    public static let transportKey = Data([
        0x01, 0x38, 0x0B, 0x9A, 0x00, 0x5B, 0x02, 0x5D,
        0xCD, 0x9E, 0xC3, 0x99, 0x09, 0x37, 0xAA, 0xE8
    ])

    public enum CipherError: Error, CustomStringConvertible {
        case badMAC(String)
        public var description: String {
            switch self {
            case let .badMAC(m): return "cipher: \"\(m)\" is not a 6-byte (12 hex digit) MAC"
            }
        }
    }

    /// `mac(6) ‖ 0 × 10`, in the order the sensor prints it.
    ///
    /// **Verified against a real activation capture.** The sensor's serial
    /// number characteristic (`0x2A25`) reads `68:7D:10:C7:C0:C2` and that is
    /// the byte order both of the IV and of the auth frame's MAC field. The
    /// vendor app's `deviceMacToByte:` walks the components backwards, which is
    /// what the earlier notes recorded — but it does so to undo a reversal it
    /// picked up elsewhere, not to introduce one. Reading the serial number and
    /// using it as-is is therefore both simplest and correct.
    public let iv: Data

    private let aes: AESOFB

    /// `transportKey` is overridable only so a capture from a different app
    /// generation can be decoded; the default is the verified constant.
    public init(mac: String, transportKey: Data = SibionicsCipher.transportKey) throws {
        let macBytes = try Self.macBytes(mac)
        var iv = Data(macBytes)
        iv.append(Data(repeating: 0, count: AESOFB.blockSize - macBytes.count))
        self.iv = iv
        aes = try AESOFB(key: transportKey)
    }

    /// Whether `mac` carries exactly six bytes of hex (any separator style).
    public static func isValidMAC(_ mac: String) -> Bool {
        (try? macBytes(mac)) != nil
    }

    /// Six bytes in the order written: upper-cases, strips separators, no
    /// reordering. See `iv` for why there is no reversal here.
    public static func macBytes(_ mac: String) throws -> Data {
        let hex = mac.uppercased().filter(\.isHexDigit)
        guard hex.count == 12 else { throw CipherError.badMAC(mac) }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else {
                throw CipherError.badMAC(mac)
            }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// In-place-symmetric: encrypts outgoing and decrypts incoming frames.
    public func apply(_ data: Data) throws -> Data {
        try aes.apply(data, iv: iv)
    }

    /// Encodes and encrypts one frame.
    public func seal(_ frame: SibionicsFrame) throws -> Data {
        try apply(frame.encoded)
    }

    /// Decrypts one notification payload. No frame validity is assumed: the
    /// sensor pads its notify value to a whole number of blocks, so the
    /// plaintext is trimmed by the frame's own length byte by the caller.
    public func open(_ data: Data) throws -> Data {
        try apply(data)
    }
}
