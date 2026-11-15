import Foundation

/// One 16-byte GS3 measurement record, as carried by the `0x32` (live),
/// `0x36` (cached latest) and `0x39` (history) packets.
///
/// Little-endian throughout. Field map from `GS3-protocol-notes.md`:
///
/// | off | field |
/// |-----|-------|
/// | 0   | temperature (raw) |
/// | 2   | dump (raw) |
/// | 4   | current (raw) |
/// | 6   | **display glucose**, mmol/L × 10; `>= 0xFF00` is a sentinel |
/// | 8   | algorithm glucose, XOR-masked |
/// | 10  | bits 0–2 trend, bit 3 `present_cstate`, bits 4–7 `algorithm_cstate` |
/// | 11  | bits 0–1 `tstate`, bits 2–4 `dstate`, bits 5–7 reserved |
/// | 12  | CE voltage (raw) |
/// | 14  | RE voltage (raw) |
public struct SibionicsRecord: Equatable, Sendable {
    public static let width = 16

    /// Blood-glucose molar mass, mg/dL per mmol/L. Matches Nightscout's
    /// `MMOL_TO_MGDL` and Android xDrip.
    public static let mmolToMgDL = 18.01559

    /// `displayGlucose >= 0xFF00` means "no result in this record".
    public static let glucoseSentinelFloor: UInt16 = 0xFF00
    /// The specific "measurement could not be produced" code.
    public static let glucoseNoResult: UInt16 = 0xFF01

    /// `AES-128-ECB(algorithmKey, 0^16)` low 16 bits, used to unmask
    /// `algorithmGlucose`. Pinned by `SibionicsRecordTests` so a bad constant
    /// can't slip in.
    public static let algorithmGlucoseKey = Data([
        0x11, 0xB8, 0xAB, 0x00, 0x01, 0x4B, 0x2A, 0x5F,
        0xCB, 0x91, 0xF3, 0xAA, 0x99, 0x27, 0xBF, 0xE0
    ])
    /// The value `algorithmGlucoseMask` must compute to. Asserted by
    /// `SibionicsCipherTests` so a wrong algorithm key cannot slip in silently.
    public static let knownAlgorithmGlucoseMask: UInt16 = 0x2CFC

    public let index: UInt16
    public let temperatureRaw: UInt16
    public let dumpRaw: UInt16
    public let currentRaw: UInt16
    public let displayGlucoseRaw: UInt16
    public let algorithmGlucoseRaw: UInt16
    public let trendBits: UInt8
    public let presentCState: Bool
    public let algorithmCState: UInt8
    public let tstate: UInt8
    public let dstate: UInt8
    public let ceVoltageRaw: UInt16
    public let reVoltageRaw: UInt16

    public init?(_ bytes: Data, index: UInt16) {
        guard bytes.count >= Self.width else { return nil }
        let b = [UInt8](bytes.prefix(Self.width))
        func u16(_ offset: Int) -> UInt16 {
            UInt16(b[offset]) | (UInt16(b[offset + 1]) << 8)
        }
        self.index = index
        temperatureRaw = u16(0)
        dumpRaw = u16(2)
        currentRaw = u16(4)
        displayGlucoseRaw = u16(6)
        algorithmGlucoseRaw = u16(8)
        trendBits = b[10] & 0x07
        presentCState = (b[10] & 0x08) != 0
        algorithmCState = (b[10] >> 4) & 0x0F
        tstate = b[11] & 0x03
        dstate = (b[11] >> 2) & 0x07
        ceVoltageRaw = u16(12)
        reVoltageRaw = u16(14)
    }

    /// True when the sensor produced a usable reading for this minute.
    public var hasGlucose: Bool { displayGlucoseRaw < Self.glucoseSentinelFloor }

    /// The value the sensor itself displays, in mmol/L (`raw / 10`).
    public var glucoseMmolL: Double? {
        hasGlucose ? Double(displayGlucoseRaw) / 10.0 : nil
    }

    /// The displayed value converted to mg/dL.
    public var glucoseMgDL: Double? {
        glucoseMmolL.map { $0 * Self.mmolToMgDL }
    }

    /// The algorithm's own (masked, higher-resolution) value, unmasked. Not used
    /// for forwarding — Juggluco also forwards the displayed value — but useful
    /// in diagnostics and when comparing against the official app.
    public func algorithmGlucose(mask: UInt16 = SibionicsRecord.algorithmGlucoseMask) -> Double {
        Double(algorithmGlucoseRaw ^ mask) / 10.0
    }

    /// The sensor's own trend code. The 0…7 → arrow mapping is **not**
    /// confirmed against a trace, so it is exposed raw and the driver derives
    /// its trend from consecutive readings instead (`SibionicsSensorMonitor`).
    public var trendCode: UInt8 { trendBits }

    /// Mask for the algorithm-glucose field: `AES-128-ECB(algorithmKey, 0^16)`
    /// low 16 bits, little-endian. Computed from the vendor key rather than
    /// hard-coded, so the two can be checked against each other.
    public static let algorithmGlucoseMask: UInt16 = {
        let zeros = Data(repeating: 0, count: 16)
        guard let masked = try? AESECB.encrypt(zeros, key: algorithmGlucoseKey), masked.count == 16 else {
            return knownAlgorithmGlucoseMask
        }
        return UInt16(masked[masked.startIndex]) | (UInt16(masked[masked.startIndex + 1]) << 8)
    }()

    public var description: String {
        let glucose = glucoseMmolL.map { String(format: "%.1f", $0) } ?? "none"
        return "seq=\(index) mmol=\(glucose) cur=\(currentRaw) t=\(temperatureRaw) "
            + "ce=\(ceVoltageRaw) re=\(reVoltageRaw) trend=\(trendBits) tstate=\(tstate) dstate=\(dstate)"
    }
}

/// A `0x32` / `0x36` / `0x39` packet after decoding.
///
/// `[len][cmd][count][start_index u16][16-byte record × count][tail u16][checksum]`
public struct SibionicsGlucosePacket: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case live
        case cached
        case history
        case other(UInt8)
    }

    public let kind: Kind
    public let startIndex: UInt16
    public let records: [SibionicsRecord]
    /// The trailing `u16` after the records. Meaning unconfirmed; kept raw so a
    /// later revision can use it without re-plumbing the decoder.
    public let tail: UInt16?

    /// A history request is answered with an empty `0x39` when nothing is left,
    /// which is how the batch is terminated.
    public var isEmptyHistoryTerminator: Bool {
        kind == .history && records.isEmpty
    }

    /// An empty history packet, for the case where the sensor answers a request
    /// with a payload that is not a record packet at all: the batch still has to
    /// terminate for the consumer. A single zero byte is the documented
    /// "nothing left" payload.
    public static var emptyHistoryTerminator: SibionicsGlucosePacket {
        guard let packet = SibionicsGlucosePacket(
            cmd: SibionicsCommand.historyRecord,
            payload: Data([0x00])
        ) else {
            preconditionFailure("a one-byte zero payload is always a valid empty packet")
        }
        return packet
    }

    public init?(cmd: UInt8, payload: Data) {
        let kind: Kind
        switch cmd {
        case SibionicsCommand.liveRecord: kind = .live
        case SibionicsCommand.cachedRecord: kind = .cached
        case SibionicsCommand.historyRecord: kind = .history
        default: kind = .other(cmd)
        }
        self.kind = kind

        guard let count = payload.first else { return nil }

        // The sensor's "nothing left" answer is `04 39 00 05 BE`: two payload
        // bytes, not the three the count/startIndex header needs. A zero count
        // is therefore the terminator, whatever else the payload carries, and
        // must not be treated as a malformed packet.
        if count == 0 {
            startIndex = 0
            records = []
            tail = payload.count >= 2 ? UInt16(payload[payload.startIndex + 1]) : nil
            return
        }

        guard payload.count >= 3 else { return nil }
        let start = payload.startIndex
        startIndex = UInt16(payload[start + 1]) | (UInt16(payload[start + 2]) << 8)

        var records: [SibionicsRecord] = []
        records.reserveCapacity(Int(count))
        var cursor = start + 3
        for i in 0 ..< Int(count) {
            guard cursor + SibionicsRecord.width <= payload.endIndex else { break }
            let slice = payload[cursor ..< cursor + SibionicsRecord.width]
            if let record = SibionicsRecord(Data(slice), index: startIndex &+ UInt16(i)) {
                records.append(record)
            }
            cursor += SibionicsRecord.width
        }
        self.records = records

        if cursor + 2 <= payload.endIndex {
            tail = UInt16(payload[cursor]) | (UInt16(payload[cursor + 1]) << 8)
        } else {
            tail = nil
        }
    }
}
