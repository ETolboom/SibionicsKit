@testable import SibionicsKit
import XCTest

final class SibionicsPlausibilityGuardTests: XCTestCase {
    func testAttentionAfterShortStreakAndBrokenAfterLonger() {
        var guardrail = SibionicsPlausibilityGuard(
            configuration: .init(currentFloor: 1.0, attentionStreak: 3, brokenStreak: 6)
        )
        XCTAssertNil(guardrail.record(sequence: 1, current: 0.2))
        XCTAssertNil(guardrail.record(sequence: 2, current: 0.2))
        XCTAssertEqual(guardrail.record(sequence: 3, current: 0.2)?.level, .attention)
        XCTAssertTrue(guardrail.attentionActive)
        XCTAssertNil(guardrail.record(sequence: 4, current: 0.2), "the attention event fires once")
        XCTAssertNil(guardrail.record(sequence: 5, current: 0.2))
        XCTAssertEqual(guardrail.record(sequence: 6, current: 0.2)?.level, .broken)
    }

    func testHealthyCurrentClearsAttention() {
        var guardrail = SibionicsPlausibilityGuard(
            configuration: .init(currentFloor: 1.0, attentionStreak: 2, brokenStreak: 5)
        )
        _ = guardrail.record(sequence: 1, current: 0.1)
        XCTAssertEqual(guardrail.record(sequence: 2, current: 0.1)?.level, .attention)
        XCTAssertNil(guardrail.record(sequence: 3, current: 900))
        XCTAssertFalse(guardrail.attentionActive)
    }

    func testReplayedSequenceDoesNotAdvanceTheStreak() {
        var guardrail = SibionicsPlausibilityGuard(
            configuration: .init(currentFloor: 1.0, attentionStreak: 2, brokenStreak: 4)
        )
        XCTAssertNil(guardrail.record(sequence: 10, current: 0.1))
        // A backfilled replay of the same index must be ignored.
        XCTAssertNil(guardrail.record(sequence: 10, current: 0.1))
        XCTAssertNil(guardrail.record(sequence: 9, current: 0.1))
        XCTAssertEqual(guardrail.record(sequence: 11, current: 0.1)?.level, .attention)
    }
}
