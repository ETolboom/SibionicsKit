import Foundation

/// Client-side "is the electrode actually working" check.
///
/// A dying GS3 electrode can keep producing a well-formed record whose displayed
/// glucose is entirely plausible — the vendor algorithm extrapolates from a
/// current that has collapsed. The raw current is the tell: a live electrode
/// carries a working current, a dead one sits at the noise floor.
///
/// Two levels, matching how this is done in the sibling kits: `attention`
/// suppresses forwarding while the streak holds (recoverable), `broken` latches
/// the sensor as failed (not recoverable within the session).
///
/// The thresholds are deliberately conservative and *not* tuned against real GS3
/// hardware yet — they are the main thing to revisit once field data exists.
public struct SibionicsPlausibilityGuard: Equatable, Sendable {
    public struct Configuration: Equatable, Sendable {
        /// Below this the electrode is considered not to be producing.
        public var currentFloor: Double
        /// Consecutive sub-floor records before forwarding is suppressed.
        public var attentionStreak: Int
        /// Consecutive sub-floor records before the sensor is declared failed.
        public var brokenStreak: Int

        public init(currentFloor: Double = 1.0, attentionStreak: Int = 3, brokenStreak: Int = 6) {
            self.currentFloor = currentFloor
            self.attentionStreak = attentionStreak
            self.brokenStreak = brokenStreak
        }

        public static let `default` = Configuration()
    }

    public enum Level: Equatable, Sendable {
        case attention
        case broken
    }

    public struct Event: Equatable, Sendable {
        public let level: Level
        public let reason: String
        public let streak: Int
    }

    public let configuration: Configuration

    private var lowStreak = 0
    private var lastSequence: UInt16?
    public private(set) var attentionActive = false

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    /// Feeds one post-warmup sample. Returns an event when a threshold is
    /// crossed on this sample (not on every sample past it).
    public mutating func record(sequence: UInt16, current: Double) -> Event? {
        if let lastSequence, sequence <= lastSequence {
            // Replays and out-of-order backfill must not advance the streak.
            return nil
        }
        lastSequence = sequence

        if current < configuration.currentFloor {
            lowStreak += 1
        } else {
            lowStreak = 0
            attentionActive = false
            return nil
        }

        if lowStreak >= configuration.brokenStreak {
            attentionActive = true
            return Event(level: .broken, reason: "electrode current at floor", streak: lowStreak)
        }
        if lowStreak >= configuration.attentionStreak {
            let wasActive = attentionActive
            attentionActive = true
            if !wasActive {
                return Event(level: .attention, reason: "electrode current at floor", streak: lowStreak)
            }
        }
        return nil
    }

    public mutating func reset() {
        lowStreak = 0
        lastSequence = nil
        attentionActive = false
    }
}
