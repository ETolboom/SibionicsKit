@testable import SibionicsKit
import XCTest

/// Activation used to be gated by a Settings toggle plus a per-pairing checkbox.
/// Neither can gate anything the sensor does not already decide: `F0 03` reports
/// the activation time, so the sensor is the authority. These tests pin the whole
/// policy, especially the case that must *never* activate.
final class SibionicsActivationPolicyTests: XCTestCase {
    private let started = Date(timeIntervalSince1970: 1_700_000_000)

    func testStartedSensorIsAttachedNotActivated() {
        XCTAssertEqual(
            SibionicsPairingService.activationDecision(
                clockAnswered: true, activationDate: started, knownActivatedAt: nil
            ),
            .alreadyActivated(started)
        )
    }

    func testFactorySensorIsActivated() {
        // The clock answered, and reported activation_time == 0.
        XCTAssertEqual(
            SibionicsPairingService.activationDecision(
                clockAnswered: true, activationDate: nil, knownActivatedAt: nil
            ),
            .activate
        )
    }

    /// The important one: a missing clock reply says nothing about whether the
    /// sensor is running, so activation must not happen on it.
    func testMissingClockReplyNeverActivates() {
        XCTAssertEqual(
            SibionicsPairingService.activationDecision(
                clockAnswered: false, activationDate: nil, knownActivatedAt: nil
            ),
            .attachReadOnly
        )
    }

    func testKnownStartTimeShortCircuitsTheClock() {
        // A reconnect passes the stored start time and never queries the clock,
        // so `clockAnswered` is false — the stored value still wins.
        XCTAssertEqual(
            SibionicsPairingService.activationDecision(
                clockAnswered: false, activationDate: nil, knownActivatedAt: started
            ),
            .alreadyActivated(started)
        )
    }
}
