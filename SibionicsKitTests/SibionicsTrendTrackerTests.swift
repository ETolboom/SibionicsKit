@testable import SibionicsKit
import XCTest

/// Cases taken from the 2026-11-18 log: the sensor re-sent the newest record
/// (seq 5225, 5400) and the official app's cache replay pushed ~20 h of old
/// records through the live path right after the live frontier.
final class SibionicsTrendTrackerTests: XCTestCase {
    private func elapsed(_ seq: UInt16) -> TimeInterval { Double(seq) * 60 }

    private func feed(
        _ tracker: inout SibionicsTrendTracker, _ seq: UInt16, _ mgDL: Double
    ) -> GlucoseSample.Trend {
        tracker.trend(sequence: seq, mgDL: mgDL, elapsed: elapsed(seq)).0
    }

    func testRepeatDeliveryKeepsTheOriginalTrend() {
        var tracker = SibionicsTrendTracker(maxGapMinutes: 6)
        XCTAssertEqual(feed(&tracker, 5220, 136), .notDetermined)
        XCTAssertEqual(feed(&tracker, 5225, 140), .stable)
        // Before: the repeat compared against itself and came out notDetermined.
        XCTAssertEqual(feed(&tracker, 5225, 140), .stable)
        XCTAssertEqual(feed(&tracker, 5225, 140), .stable)
    }

    func testRepeatKeepsTheRate() {
        var tracker = SibionicsTrendTracker(maxGapMinutes: 6)
        _ = tracker.trend(sequence: 100, mgDL: 100, elapsed: elapsed(100))
        let first = tracker.trend(sequence: 105, mgDL: 112, elapsed: elapsed(105))
        let again = tracker.trend(sequence: 105, mgDL: 112, elapsed: elapsed(105))
        XCTAssertEqual(first.0, .rising)
        XCTAssertEqual(first.1 ?? 0, 2.4, accuracy: 1e-9)
        XCTAssertEqual(again.1, first.1)
    }

    func testOlderReplayDoesNotDisturbTheLiveNeighbour() {
        var tracker = SibionicsTrendTracker(maxGapMinutes: 6)
        _ = feed(&tracker, 5220, 136)
        _ = feed(&tracker, 5225, 140)
        // A burst of yesterday's records arrives after the live frontier.
        for (i, seq) in stride(from: UInt16(3995), through: 4100, by: 5).enumerated() {
            _ = feed(&tracker, seq, 230 + Double(i))
        }
        // Before: the next live reading compared against seq 4100 (gap too big)
        // and came out notDetermined; it should still see 5225.
        XCTAssertEqual(feed(&tracker, 5230, 141), .stable)
    }

    func testReplayedRecordsStillGetTrendsAmongThemselves() {
        var tracker = SibionicsTrendTracker(maxGapMinutes: 6)
        _ = feed(&tracker, 5225, 140)
        XCTAssertEqual(feed(&tracker, 4000, 230), .notDetermined)
        XCTAssertEqual(feed(&tracker, 4005, 232), .stable)
        XCTAssertEqual(feed(&tracker, 4010, 243), .rising)
    }

    func testOutOfOrderBackfillUsesNearestEarlierNeighbour() {
        var tracker = SibionicsTrendTracker(maxGapMinutes: 6)
        _ = feed(&tracker, 100, 100)
        _ = feed(&tracker, 110, 100)
        // 105 arrives late; its neighbour is 100, not 110.
        XCTAssertEqual(feed(&tracker, 105, 90), .falling)
    }

    func testChangedValueForKnownIndexIsRecomputed() {
        var tracker = SibionicsTrendTracker(maxGapMinutes: 6)
        _ = feed(&tracker, 100, 100)
        XCTAssertEqual(feed(&tracker, 105, 101), .stable)
        XCTAssertEqual(feed(&tracker, 105, 112), .rising)
        XCTAssertEqual(tracker.entries.filter { $0.sequence == 105 }.count, 1)
    }

    func testGapLongerThanLimitIsNotDetermined() {
        var tracker = SibionicsTrendTracker(maxGapMinutes: 6)
        _ = feed(&tracker, 100, 100)
        XCTAssertEqual(feed(&tracker, 110, 100), .notDetermined)
    }

    func testWindowIsBounded() {
        var tracker = SibionicsTrendTracker(maxGapMinutes: 6)
        for seq in stride(from: UInt16(0), to: 1000, by: 5) { _ = feed(&tracker, seq, 100) }
        XCTAssertEqual(tracker.entries.count, SibionicsTrendTracker.capacity)
    }
}
