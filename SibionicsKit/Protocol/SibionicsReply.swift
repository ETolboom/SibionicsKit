import Foundation

/// A parsed sensor reply.
///
/// Replies use the same `[len][cmd][payload][checksum]` framing as requests.
/// **Verified against a real activation capture**: the auth ack is the five
/// bytes `04 E2 01 00 19`, not the three-byte `E2 01 00` the earlier notes
/// recorded (that was a summary of cmd + status + code). The length byte and
/// the checksum are therefore a hard gate, which is what makes a wrong MAC or a
/// corrupt frame fail closed instead of parsing as something plausible.
///
/// There is no lenient fallback on purpose: a decrypt with the wrong IV produces
/// noise, and a parser that accepts noise as a "command-first reply" would turn
/// a decryption failure into a bogus success.
public struct SibionicsReply: Equatable, Sendable {
    /// The `04 00 00 00 FC` frame a sensor sends instead of a real answer while
    /// the session is unauthenticated. Sums to zero and carries `cmd == 0x00`,
    /// so it is easy to mistake for a valid but odd reply.
    public static let unauthenticatedBootstrap = Data([0x04, 0x00, 0x00, 0x00, 0xFC])

    public let cmd: UInt8
    public let payload: Data
    public let raw: Data

    public var isUnauthenticatedBootstrap: Bool { raw == Self.unauthenticatedBootstrap }

    /// First payload byte. For the auth ack `E2 01 00` this is `0x01`.
    public var status: UInt8? { payload.first }

    public init(cmd: UInt8, payload: Data, raw: Data) {
        self.cmd = cmd
        self.payload = payload
        self.raw = raw
    }

    /// Parses a decrypted notify value. `bytes` may carry the sensor's block
    /// padding, which the length byte trims off.
    public init?(decoding bytes: Data) {
        guard let size = SibionicsFrame.trimmedSize(of: bytes),
              let frame = try? SibionicsFrame(decoding: bytes)
        else { return nil }
        self.init(cmd: frame.cmd, payload: frame.payload, raw: Data(bytes.prefix(size)))
    }

    public var description: String {
        String(format: "cmd=0x%02x [%d] %@", cmd, payload.count, raw.hexDescription)
    }
}
