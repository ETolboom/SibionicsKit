import Foundation

/// Decodes a captured `ff31`/`ff32` trace back into frames and field values.
///
/// This exists so a hardware capture can be read with the *same* cipher and
/// record parser the driver uses — if the driver's understanding of the
/// protocol is wrong, the decoder is wrong in exactly the same way, which is a
/// far more useful signal than a second, independent implementation would be.
///
/// The highest-value thing it recovers: the auth frame's plaintext carries the
/// 16-byte registration key and the 12-byte account id, so one capture answers
/// questions that would otherwise need the app to be unpacked.
public enum SibionicsCaptureDecoder {
    public enum Direction: String, Sendable {
        /// Sensor → phone (notify on `ff31`).
        case sensor
        /// Phone → sensor (write on `ff32`).
        case phone
    }

    /// One ATT value lifted out of a capture, before decryption.
    public struct Captured: Sendable, Equatable {
        public let direction: Direction?
        public let value: Data
        public init(direction: Direction?, value: Data) {
            self.direction = direction
            self.value = value
        }
    }

    public struct Decoded: Sendable {
        public let direction: Direction?
        public let ciphertext: Data
        public let plaintext: Data
        public let reply: SibionicsReply
        /// Field-level annotations, one per line.
        public let notes: [String]
    }

    /// Parses one line of a text capture: an optional direction word (`phone`,
    /// `sensor`, `tx`, `rx`) followed by hex. Returns nil for blank or
    /// comment lines so whole files can be piped in.
    public static func parseLine(_ line: String) -> (direction: Direction?, bytes: Data)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }

        var direction: Direction?
        var rest = trimmed
        if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "," }) {
            let head = trimmed[..<space].lowercased()
            switch head {
            case "->",
                 "phone",
                 "tx",
                 "write": direction = .phone
            case "<-",
                 "notify",
                 "rx",
                 "sensor": direction = .sensor
            default: direction = nil
            }
            if direction != nil {
                rest = String(trimmed[trimmed.index(after: space)...])
            }
        }

        let hex = rest.filter(\.isHexDigit)
        guard hex.count >= 4, hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return (direction, Data(bytes))
    }

    public static func decode(_ bytes: Data, direction: Direction?, cipher: SibionicsCipher) -> Decoded? {
        guard let plaintext = try? cipher.apply(bytes) else { return nil }
        guard let reply = SibionicsReply(decoding: plaintext) else { return nil }
        return Decoded(
            direction: direction,
            ciphertext: bytes,
            plaintext: plaintext,
            reply: reply,
            notes: notes(for: reply, direction: direction)
        )
    }

    // MARK: - Field annotations

    static func notes(for reply: SibionicsReply, direction: Direction?) -> [String] {
        var out: [String] = []
        let payload = reply.payload

        switch reply.cmd {
        case SibionicsCommand.auth:
            out.append("AUTH")
            // A request is the only 35-byte payload on this opcode:
            // [pad][mac 6][registration key 16][account id 12].
            if payload.count == 35 {
                let bytes = [UInt8](payload)
                let mac = Data(bytes[1 ..< 7]).map { String(format: "%02X", $0) }
                    .joined(separator: ":")
                let registration = Data(bytes[7 ..< 23])
                let account = Data(bytes[23 ..< 35])
                out.append("  mac on the wire:       \(mac)")
                out.append("                        (same order as the sensor's 0x2A25 serial number)")
                out.append("  registration key hex:  \(registration.hexDescription)")
                out.append("  registration key text: \"\(String(data: registration, encoding: .utf8) ?? "<not utf8>")\"")
                out.append("  account id (12 B):     \(account.hexDescription)")
                if let text = String(data: registration, encoding: .utf8) {
                    out.append("  known key match:       \(Self.describeKnownKey(registration, text: text))")
                }
            } else {
                out
                    .append(
                        "  ack payload \(payload.hexDescription) status=\(reply.status.map { String(format: "0x%02x", $0) } ?? "none")"
                    )
                out.append("  (documented success is 01 00; anything else is a refusal)")
            }

        case SibionicsCommand.activateBindIn:
            if payload.count >= 16 {
                let bytes = [UInt8](payload)
                let seconds = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8)
                    | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
                let account = Data(bytes[4 ..< 16])
                let date = Date(timeIntervalSince1970: TimeInterval(seconds))
                out.append("ACTIVATE (0x35)")
                out.append("  activation time: \(seconds) = \(date)")
                out.append("  account id:      \(account.hexDescription)")
            } else {
                out.append("ACTIVATE ack: \(payload.hexDescription)")
                if let ack = SibionicsSession.ActivationAck.parse(payload) {
                    out.append(String(format: "  status: 0x%02x%@", ack.status, ack.isSuccess ? " (ok)" : " (refused)"))
                    out.append("  echoed activation time: \(ack.timestamp) = \(ack.activationDate)")
                }
            }

        case SibionicsCommand.infoQuery:
            out.append("INFO QUERY")
            let bytes = [UInt8](payload)
            guard let sub = bytes.first else {
                out.append("  (empty)")
                break
            }
            if bytes.count == 1 {
                out.append(String(format: "  request sub 0x%02x", sub))
                break
            }
            // A reply echoes the sub first. Only 0x03 carries the clock; treating
            // every long reply as a timestamp decodes nonsense, which is exactly
            // what the first pass at this did with `F0 0E`.
            out.append(String(format: "  reply sub 0x%02x", sub))
            let body = Data(bytes.dropFirst())
            if sub == SibionicsCommand.infoDeviceTime, body.count >= 14,
               let time = try? SibionicsSession.parseDeviceTime(body)
            {
                out.append(
                    "  device time: startover=\(time.startover) activation=\(time.activation) "
                        + "current=\(time.current) last=\(time.last) lastIndex=\(time.lastIndex)"
                )
                out.append(
                    "  activated: \(time.isActivated)"
                        + (time.activationDate.map { " at \($0)" } ?? "")
                        + (time.elapsedSeconds.map { " elapsed=\(Int($0))s" } ?? "")
                )
            } else {
                // Info payloads are `sub ‖ status ‖ ascii ‖ zero padding`.
                out.append("  \(body.count) B: \(body.hexDescription)")
                let run = body.drop { $0 < 0x20 }.prefix { $0 >= 0x20 && $0 < 0x7F }
                if run.count >= 3, let text = String(bytes: run, encoding: .utf8) {
                    out.append("  text: \"\(text)\"")
                }
            }

        case SibionicsCommand.deactivate:
            out.append("DEACTIVATE (0xE0) payload \(payload.hexDescription)")

        case SibionicsCommand.cachedRecord,
             SibionicsCommand.historyRecord,
             SibionicsCommand.liveRecord:
            // A `0x39` from the phone is a *request* and has the same opcode as
            // the records coming back, so direction decides how to read it.
            if reply.cmd == SibionicsCommand.historyRecord, direction == .phone, payload.count == 4 {
                let bytes = [UInt8](payload)
                let first = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
                let last = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
                out.append("HISTORY REQUEST  first=\(first) last=\(last)")
                break
            }
            guard let packet = SibionicsGlucosePacket(cmd: reply.cmd, payload: payload) else {
                out.append("record packet could not be parsed (\(payload.count) B)")
                break
            }
            let kind: String
            switch packet.kind {
            case .live: kind = "live 0x32"
            case .cached: kind = "cached 0x36"
            case .history: kind = "history 0x39"
            case let .other(cmd): kind = String(format: "0x%02x", cmd)
            }
            let tail = packet.tail.map { String(format: " tail=0x%04x", $0) } ?? ""
            out.append("\(kind) startIndex=\(packet.startIndex) records=\(packet.records.count)\(tail)")
            if packet.records.isEmpty { out.append("  (empty packet — the batch terminator)") }
            for record in packet.records {
                let glucose = record.glucoseMmolL
                    .map { String(format: "%.1f mmol/L (%.0f mg/dL)", $0, $0 * SibionicsRecord.mmolToMgDL) }
                    ?? "no result (0x\(String(record.displayGlucoseRaw, radix: 16)))"
                let flags = record.presentCState ? " cstate=PRESENT" : ""
                out.append(
                    "  #\(record.index) \(glucose) cur=\(record.currentRaw) temp=\(record.temperatureRaw) "
                        + "ce=\(record.ceVoltageRaw) re=\(record.reVoltageRaw) trend=\(record.trendBits) "
                        +
                        "tstate=\(record.tstate) dstate=\(record.dstate) alg=\(String(format: "%.2f", record.algorithmGlucose()))\(flags)"
                )
            }

        default:
            out.append(String(format: "cmd 0x%02x payload %@", reply.cmd, payload.hexDescription))
        }

        return out
    }

    private static func describeKnownKey(_ key: Data, text: String) -> String {
        if let match = SibionicsRegistrationKey.known.first(where: { $0.key == key }) {
            return match.verified ? "\(match.label) (verified)" : "\(match.label) (unverified)"
        }
        if !text.allSatisfy({ $0.isASCII && !$0.isNewline }) { return "not printable — unknown key" }
        return "unknown — add it to SibionicsRegistrationKey"
    }
}

public extension Data {
    /// Lower-case hex, no separators.
    var hexDescription: String { map { String(format: "%02x", $0) }.joined() }
}
