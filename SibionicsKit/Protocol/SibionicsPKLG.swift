import Foundation

/// Reads Apple's PacketLogger `.pklg` container, which is what you get from
/// *Additional Tools for Xcode* against an iPhone.
///
/// Record layout, from a real capture:
///
///     [u32 length] [u32 seconds][u32 microseconds] [u8 type] [length-9 bytes]
///
/// `length` counts everything after itself. `type` is `0` HCI command, `1` HCI
/// event, `2` ACL host→controller, `3` ACL controller→host, and `252`/`253` for
/// PacketLogger's own log lines. ACL records then carry the same
/// `[handle u16][length u16][L2CAP…]` framing as `btsnoop`, so the ATT
/// extraction is shared with `SibionicsBTSnoop` — and direction is taken from
/// the ATT opcode rather than from `type`, so the two agree.
public enum SibionicsPKLG {
    public enum ParseError: Error, CustomStringConvertible {
        case empty
        case truncated(at: Int)
        case noTraffic

        public var description: String {
            switch self {
            case .empty: return "the file is empty"
            case let .truncated(offset): return "pklg record at offset \(offset) runs past the end of the file"
            case .noTraffic: return "no HCI ACL records in this pklg — was the logger attached to a device?"
            }
        }
    }

    /// Cheap structural sniff, so a caller can try this format before falling
    /// back to text. `btsnoop` starts with an ASCII magic; `pklg` starts with a
    /// plausible little-endian record length and has a known type byte at
    /// offset 8.
    public static func looksLikePKLG(_ data: Data) -> Bool {
        guard data.count >= 24, !SibionicsBTSnoop.isBTSnoop(data) else { return false }
        let bytes = [UInt8](data.prefix(24))
        let length = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        guard length >= 9, Int(length) + 4 <= data.count else { return false }
        // Layout after the length word: seconds (4), microseconds (4), type (1).
        return [0, 1, 2, 3, 252, 253].contains(bytes[12])
    }

    public static func parse(_ data: Data) throws -> SibionicsBTSnoop.Capture {
        guard !data.isEmpty else { throw ParseError.empty }
        let bytes = [UInt8](data)

        var frames: [SibionicsCaptureDecoder.Captured] = []
        var skipped = 0
        var recordCount = 0
        var offset = 0
        var first: Date?
        var last: Date?

        while offset + 9 <= bytes.count {
            let length = Int(
                UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                    | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
            )
            guard length >= 9 else { break }
            let bodyStart = offset + 4
            guard bodyStart + length <= bytes.count else { throw ParseError.truncated(at: offset) }
            recordCount += 1

            let seconds = UInt32(bytes[bodyStart]) | (UInt32(bytes[bodyStart + 1]) << 8)
                | (UInt32(bytes[bodyStart + 2]) << 16) | (UInt32(bytes[bodyStart + 3]) << 24)
            let micros = UInt32(bytes[bodyStart + 4]) | (UInt32(bytes[bodyStart + 5]) << 8)
                | (UInt32(bytes[bodyStart + 6]) << 16) | (UInt32(bytes[bodyStart + 7]) << 24)
            if seconds > 1_000_000_000, seconds < 4_000_000_000 {
                let date = Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(micros) / 1_000_000)
                if first == nil { first = date }
                last = date
            }

            let type = bytes[bodyStart + 8]
            let payload = bytes[(bodyStart + 9) ..< (bodyStart + length)]
            offset = bodyStart + length

            // 2 = ACL host→controller, 3 = ACL controller→host.
            guard type == 2 || type == 3 else { continue }
            if let values = SibionicsBTSnoop.attValues(inACL: payload) {
                frames.append(contentsOf: values.map {
                    SibionicsCaptureDecoder.Captured(direction: $0.direction, value: $0.value)
                })
            } else {
                skipped += 1
            }
        }

        guard recordCount > 0 else { throw ParseError.empty }
        guard !frames.isEmpty else { throw ParseError.noTraffic }
        return SibionicsBTSnoop.Capture(
            frames: frames, skipped: skipped, startedAt: first, endedAt: last
        )
    }
}
