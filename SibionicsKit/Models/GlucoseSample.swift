import Foundation

/// One forwarded measurement, already dated on the sensor's own clock.
public struct GlucoseSample: Equatable, Sendable {
    public enum Trend: Equatable, Sendable {
        case notDetermined
        case fallingQuickly
        case falling
        case stable
        case rising
        case risingQuickly
    }

    public enum Source: Equatable, Sendable {
        case realtime
        case historicalBackfill
    }

    public enum Condition: Equatable, Sendable {
        case belowRange
        case aboveRange
    }

    public let date: Date
    public let valueMgDL: Double
    public let trend: Trend
    public let rateOfChangeMgDLPerMinute: Double?
    public let condition: Condition?

    /// The sensor's running record index. Ticks once a minute from activation
    /// and is the dedup key everywhere: `syncIdentifier`, the forwarding grid,
    /// and backfill watermarking all use it rather than wall-clock time.
    public let sequence: UInt16

    public let rawDisplayMgDL: Double
    /// Raw electrode current, fed to the plausibility check.
    public let rawCurrent: Double?
    /// Seconds since activation according to the sensor's own clock.
    public let elapsedSeconds: TimeInterval?

    public let hasBlockingIssue: Bool
    public let source: Source
    public let wasForwarded: Bool
    public let forwardSkipReason: String?

    public init(
        date: Date,
        valueMgDL: Double,
        trend: Trend,
        rateOfChangeMgDLPerMinute: Double?,
        sequence: UInt16,
        rawDisplayMgDL: Double,
        rawCurrent: Double? = nil,
        elapsedSeconds: TimeInterval? = nil,
        condition: Condition? = nil,
        hasBlockingIssue: Bool = false,
        source: Source = .realtime,
        wasForwarded: Bool = false,
        forwardSkipReason: String? = nil
    ) {
        self.date = date
        self.valueMgDL = valueMgDL
        self.trend = trend
        self.rateOfChangeMgDLPerMinute = rateOfChangeMgDLPerMinute
        self.sequence = sequence
        self.rawDisplayMgDL = rawDisplayMgDL
        self.rawCurrent = rawCurrent
        self.elapsedSeconds = elapsedSeconds
        self.condition = condition
        self.hasBlockingIssue = hasBlockingIssue
        self.source = source
        self.wasForwarded = wasForwarded
        self.forwardSkipReason = forwardSkipReason
    }

    public func withForwardingOutcome(wasForwarded: Bool, skipReason: String?) -> GlucoseSample {
        GlucoseSample(
            date: date, valueMgDL: valueMgDL, trend: trend,
            rateOfChangeMgDLPerMinute: rateOfChangeMgDLPerMinute, sequence: sequence,
            rawDisplayMgDL: rawDisplayMgDL, rawCurrent: rawCurrent, elapsedSeconds: elapsedSeconds,
            condition: condition, hasBlockingIssue: hasBlockingIssue, source: source,
            wasForwarded: wasForwarded, forwardSkipReason: skipReason
        )
    }
}

// MARK: - Persistence

extension GlucoseSample {
    init?(rawValue: [String: Any]) {
        guard let date = rawValue["d"] as? Date,
              let value = rawValue["v"] as? Double,
              let seq = (rawValue["sq"] as? Int).map({ UInt16(clamping: $0) }),
              let trendRaw = rawValue["tr"] as? String,
              let trend = Trend(rawString: trendRaw)
        else { return nil }
        self.date = date
        valueMgDL = value
        self.trend = trend
        rateOfChangeMgDLPerMinute = rawValue["r"] as? Double
        sequence = seq
        rawDisplayMgDL = rawValue["rd"] as? Double ?? value
        rawCurrent = rawValue["rc"] as? Double
        elapsedSeconds = rawValue["es"] as? Double
        source = (rawValue["s"] as? String).flatMap(Source.init(rawString:)) ?? .realtime
        wasForwarded = rawValue["fw"] as? Bool ?? false
        forwardSkipReason = rawValue["fr"] as? String
        hasBlockingIssue = rawValue["bi"] as? Bool ?? false
        condition = (rawValue["c"] as? String).flatMap(Condition.init(rawString:))
    }

    var rawValue: [String: Any] {
        var raw: [String: Any] = [
            "d": date, "v": valueMgDL, "sq": Int(sequence),
            "tr": trend.rawString, "rd": rawDisplayMgDL
        ]
        raw["r"] = rateOfChangeMgDLPerMinute
        raw["rc"] = rawCurrent
        raw["es"] = elapsedSeconds
        if source != .realtime { raw["s"] = source.rawString }
        if wasForwarded { raw["fw"] = true }
        raw["fr"] = forwardSkipReason
        if hasBlockingIssue { raw["bi"] = true }
        if let condition { raw["c"] = condition.rawString }
        return raw
    }
}

extension GlucoseSample.Condition {
    fileprivate var rawString: String { self == .belowRange ? "lo" : "hi" }
    init?(rawString: String) {
        switch rawString {
        case "lo": self = .belowRange
        case "hi": self = .aboveRange
        default: return nil
        }
    }
}

extension GlucoseSample.Source {
    fileprivate var rawString: String { self == .realtime ? "rt" : "hb" }
    init?(rawString: String) {
        switch rawString {
        case "rt": self = .realtime
        case "hb": self = .historicalBackfill
        default: return nil
        }
    }
}

extension GlucoseSample.Trend {
    fileprivate var rawString: String {
        switch self {
        case .notDetermined: return "u"
        case .fallingQuickly: return "ff"
        case .falling: return "f"
        case .stable: return "s"
        case .rising: return "r"
        case .risingQuickly: return "rr"
        }
    }

    init?(rawString: String) {
        switch rawString {
        case "u": self = .notDetermined
        case "ff": self = .fallingQuickly
        case "f": self = .falling
        case "s": self = .stable
        case "r": self = .rising
        case "rr": self = .risingQuickly
        default: return nil
        }
    }
}
