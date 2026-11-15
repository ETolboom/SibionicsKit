import Foundation

/// Reads a `btsnoop` HCI dump (Android's `btsnoop_hci.log`, and what Apple's
/// PacketLogger can export) and hands back the ATT values worth decoding.
///
/// Only what a GS3 conversation needs is implemented: HCI UART / unencrypted
/// ACL packets carrying a single short ATT PDU. That covers every write and
/// notify in this protocol (the largest is well under one ACL packet). It does
/// not reassemble fragmented or multiplexed PDUs, and it says so rather than
/// guessing.
///
/// Direction is taken from the ATT opcode, not from the record's flags word:
/// the meaning of that bit is inconsistent between producers, whereas a
/// notification is always sensor→phone and a write always phone→sensor.
public enum SibionicsBTSnoop {
    public enum ParseError: Error, CustomStringConvertible {
        case badMagic
        case unsupportedVersion(UInt32)
        case unsupportedDatalink(UInt32)
        case truncated(at: Int)

        public var description: String {
            switch self {
            case .badMagic: return "not a btsnoop file (missing \"btsnoop\\0\" magic)"
            case let .unsupportedVersion(v): return "unsupported btsnoop version \(v)"
            case let .unsupportedDatalink(d):
                return "unsupported btsnoop datalink \(d); only HCI UART (1002) and "
                    + "unencrypted HCI (1001) are handled"
            case let .truncated(offset): return "btsnoop truncated at offset \(offset)"
            }
        }
    }

    public struct Capture: Sendable {
        public let frames: [SibionicsCaptureDecoder.Captured]
        /// ACL packets skipped because they needed reassembly or were malformed.
        public let skipped: Int
        /// The capture's first and last timestamps, when the records carried them.
        public let startedAt: Date?
        public let endedAt: Date?
    }

    static let magic = Data("btsnoop\0".utf8)

    /// HCI type byte used in `btsnoop`'s "HCI UART (H4)" datalink.
    private enum H4 {
        static let command: UInt8 = 0x01
        static let aclFromHost: UInt8 = 0x02
        static let event: UInt8 = 0x04
        static let aclToHost: UInt8 = 0x05
    }

    private static let l2capATT: UInt16 = 0x0004

    public static func isBTSnoop(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    public static func parse(_ data: Data) throws -> Capture {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, Data(bytes[0 ..< 8]) == magic else { throw ParseError.badMagic }

        let version = read32(bytes, 8)
        guard version == 1 else { throw ParseError.unsupportedVersion(version) }
        let datalink = read32(bytes, 12)
        let hasH4Type: Bool
        switch datalink {
        case 1002:
            hasH4Type = true
        case 1001:
            hasH4Type = false
        default:
            throw ParseError.unsupportedDatalink(datalink)
        }

        var frames: [SibionicsCaptureDecoder.Captured] = []
        var skipped = 0
        var offset = 16
        var first: Date?
        var last: Date?

        while offset + 24 <= bytes.count {
            let included = Int(read32(bytes, offset + 4))
            let timestamp = read64(bytes, offset + 16)
            let recordStart = offset + 24
            guard included >= 0, recordStart + included <= bytes.count else {
                throw ParseError.truncated(at: offset)
            }
            let packet = Array(bytes[recordStart ..< recordStart + included])
            offset = recordStart + included

            if let date = date(fromBTSnoopMicroseconds: timestamp) {
                if first == nil { first = date }
                last = date
            }

            var acl = packet[...]
            if hasH4Type {
                guard let type = acl.first else { continue }
                acl = acl.dropFirst()
                // Only ACL carries ATT; commands and events do not.
                guard type == H4.aclFromHost || type == H4.aclToHost else { continue }
            }

            if let values = attValues(inACL: acl) {
                for value in values {
                    frames.append(SibionicsCaptureDecoder.Captured(
                        direction: value.direction, value: value.value
                    ))
                }
            } else {
                skipped += 1
            }
        }

        return Capture(frames: frames, skipped: skipped, startedAt: first, endedAt: last)
    }

    // MARK: - ATT extraction

    struct AttValue {
        let direction: SibionicsCaptureDecoder.Direction
        let value: Data
    }

    /// Returns the ATT values in one ACL payload, or nil when the packet needed
    /// something this parser does not do (reassembly, multiple PDUs).
    static func attValues(inACL acl: ArraySlice<UInt8>) -> [AttValue]? {
        let bytes = Array(acl)
        guard bytes.count >= 5 else { return nil }
        // HCI ACL: handle+flags (2), data length (2), then L2CAP.
        let aclLength = Int(bytes[2]) | (Int(bytes[3]) << 8)
        guard bytes.count >= 4 + aclLength else { return nil }

        var cursor = 4
        let end = 4 + aclLength
        var values: [AttValue] = []

        while cursor + 4 <= end {
            let l2capLength = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            let channel = UInt16(bytes[cursor + 2]) | (UInt16(bytes[cursor + 3]) << 8)
            let pduStart = cursor + 4
            let pduEnd = pduStart + l2capLength
            guard pduEnd <= end, l2capLength >= 3 else { return nil }
            defer { cursor = pduEnd }
            guard channel == l2capATT else { continue }

            // A second PDU in one ACL packet would need per-PDU reassembly
            // bookkeeping; bail out rather than silently mis-order the stream.
            guard values.isEmpty else { return nil }

            let opcode = bytes[pduStart]
            let body = Array(bytes[(pduStart + 1) ..< pduEnd])
            switch opcode {
            case 0x1B: // Handle Value Notification: handle(2) + value
                guard body.count >= 2 else { return nil }
                values.append(AttValue(direction: .sensor, value: Data(body.dropFirst(2))))
            case 0x12,
                 0x52: // Write Request / Write Command: handle(2) + value
                guard body.count >= 2 else { return nil }
                values.append(AttValue(direction: .phone, value: Data(body.dropFirst(2))))
            case 0x1D: // Handle Value Indication, same shape as a notification
                guard body.count >= 2 else { return nil }
                values.append(AttValue(direction: .sensor, value: Data(body.dropFirst(2))))
            default:
                // Reads, responses, CCCD writes: not part of the protocol layer.
                continue
            }
        }
        return values
    }

    // MARK: - Little-endian reads

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func read64(_ bytes: [UInt8], _ offset: Int) -> Int64 {
        var value: UInt64 = 0
        for index in 0 ..< 8 {
            value |= UInt64(bytes[offset + index]) << (8 * UInt64(index))
        }
        return Int64(bitPattern: value)
    }

    /// btsnoop timestamps are microseconds since 0000-01-01. The epoch delta is
    /// `0x00dcddb30f2f8000` µs — the constant every btsnoop producer and reader
    /// agrees on (Wireshark's `BTSNOOP_EPOCH_DELTA`). Using the 0001-01-01
    /// delta here instead is a 366-day mistake.
    static let epochDeltaMicroseconds: Int64 = 62_167_219_200_000_000

    static func date(fromBTSnoopMicroseconds value: Int64) -> Date? {
        guard value > 0 else { return nil }
        let unix = Double(value - epochDeltaMicroseconds) / 1_000_000
        guard unix >= 0 else { return nil }
        return Date(timeIntervalSince1970: unix)
    }
}
