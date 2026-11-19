import Foundation

/// Derives a trend from recent readings, keyed by sensor index.
///
/// Used to keep only "the last reading" and compare each new one against it.
/// That broke in two ways the logs showed:
/// - a repeat delivery of the same index (the sensor re-sends the newest
///   record on reconnect, or when another app syncs) compared against itself
///   and came out `notDetermined`, overwriting a good arrow for the current
///   reading;
/// - an older record arriving after a newer one (a cache replay) replaced the
///   tracker's state, so the next live reading compared against a stale value.
///
/// Instead this keeps a short window of recent readings. A repeat returns the
/// trend it was first given, and any reading is compared against its nearest
/// earlier neighbour in the window, whatever order they arrived in.
struct SibionicsTrendTracker {
    struct Entry {
        let sequence: UInt16
        let mgDL: Double
        let elapsed: TimeInterval
        let trend: GlucoseSample.Trend
        let rate: Double?
    }

    /// Readings land every 5 records, so 32 covers well over two hours.
    static let capacity = 32
    let maxGapMinutes: Double

    /// Oldest inserted first; a replay can make this out of sequence order.
    private(set) var entries: [Entry] = []

    init(maxGapMinutes: Double) {
        self.maxGapMinutes = maxGapMinutes
    }

    mutating func trend(
        sequence: UInt16, mgDL: Double, elapsed: TimeInterval
    ) -> (GlucoseSample.Trend, Double?) {
        if let existing = entries.last(where: { $0.sequence == sequence }), existing.mgDL == mgDL {
            return (existing.trend, existing.rate)
        }
        // A changed value for a known index replaces it.
        entries.removeAll { $0.sequence == sequence }

        let previous = entries
            .filter { $0.sequence < sequence }
            .max { $0.sequence < $1.sequence }

        var result: (GlucoseSample.Trend, Double?) = (.notDetermined, nil)
        if let previous {
            let minutes = (elapsed - previous.elapsed) / 60
            if minutes > 0, minutes <= maxGapMinutes {
                let rate = (mgDL - previous.mgDL) / minutes
                result = (Self.classify(rate), rate)
            }
        }

        entries.append(Entry(sequence: sequence, mgDL: mgDL, elapsed: elapsed, trend: result.0, rate: result.1))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return result
    }

    static func classify(_ rate: Double) -> GlucoseSample.Trend {
        if rate <= -3 { return .fallingQuickly }
        if rate <= -2 { return .falling }
        if rate < 2 { return .stable }
        if rate < 3 { return .rising }
        return .risingQuickly
    }
}
