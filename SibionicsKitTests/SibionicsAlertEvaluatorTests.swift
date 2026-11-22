@testable import SibionicsKit
import XCTest

/// What should be raised, and — more importantly — what should not. A driver
/// that alerts when nothing is wrong is worse than one that stays quiet.
final class SibionicsAlertEvaluatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func due(
        paired: Bool = true,
        lastReadingAge: TimeInterval? = 60,
        fault: SibionicsSensorFault.Kind? = nil,
        expired: Bool = false,
        sinceLaunch: TimeInterval? = nil
    ) -> Set<SibionicsAlert> {
        SibionicsAlertEvaluator.dueAlerts(
            sensorPaired: paired,
            latestReadingAt: lastReadingAge.map { now.addingTimeInterval(-$0) },
            reportedFault: fault,
            expired: expired,
            launchedAt: sinceLaunch.map { now.addingTimeInterval(-$0) },
            now: now
        )
    }

    /// After a long quit the last reading is hours old; signal loss waits for
    /// the first reconnect instead of flashing at launch.
    func testSignalLossWaitsOutTheLaunchGrace() {
        XCTAssertEqual(due(lastReadingAge: 9 * 3600, sinceLaunch: 2), [])
        XCTAssertEqual(due(lastReadingAge: 9 * 3600, sinceLaunch: 2 * 60 - 1), [])
        XCTAssertEqual(due(lastReadingAge: 9 * 3600, sinceLaunch: 2 * 60), [.signalLoss])
    }

    /// The grace is only for signal loss: a dead or expired sensor is known
    /// without a connection.
    func testLaunchGraceDoesNotDelayFailedOrExpired() {
        XCTAssertEqual(due(fault: .signalImplausible, sinceLaunch: 2), [.sensorFailed])
        XCTAssertEqual(due(expired: true, sinceLaunch: 2), [.sensorExpired])
    }

    func testQuietWhenEverythingIsFine() {
        XCTAssertEqual(due(), [])
    }

    func testNothingIsRaisedWithoutASensor() {
        XCTAssertEqual(due(paired: false, lastReadingAge: 7200, fault: .signalImplausible, expired: true), [])
    }

    func testSignalLossOnlyAfterTheThreshold() {
        XCTAssertEqual(due(lastReadingAge: 20 * 60 - 1), [])
        XCTAssertEqual(due(lastReadingAge: 20 * 60), [.signalLoss])
    }

    /// Before the first reading there is nothing to have lost.
    func testNoReadingYetIsNotSignalLoss() {
        XCTAssertEqual(due(lastReadingAge: nil), [])
    }

    func testFaultRaisesSensorFailed() {
        XCTAssertEqual(due(fault: .signalImplausible), [.sensorFailed])
    }

    func testExpiryRaisesSensorExpired() {
        XCTAssertEqual(due(expired: true), [.sensorExpired])
    }

    /// The same event, not three of them: a failed or expired sensor goes quiet
    /// as a consequence, and a second "no readings" alert adds nothing.
    func testSignalLossIsSuppressedWhenTheSensorIsAlreadyGone() {
        XCTAssertEqual(due(lastReadingAge: 3600, fault: .signalImplausible), [.sensorFailed])
        XCTAssertEqual(due(lastReadingAge: 3600, expired: true), [.sensorExpired])
    }

    func testAlertIdentifiersAreStable() {
        // The host reconciles by identifier, so these must not drift.
        XCTAssertEqual(SibionicsAlert.signalLoss.identifier, "signalLoss")
        XCTAssertEqual(SibionicsAlert.sensorFailed.identifier, "sensorFailed")
        XCTAssertEqual(SibionicsAlert.sensorExpired.identifier, "sensorExpired")
        XCTAssertEqual(Set(SibionicsAlert.allCases).count, SibionicsAlert.allCases.count)
    }
}
