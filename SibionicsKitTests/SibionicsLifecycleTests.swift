@testable import SibionicsKit
import XCTest

final class SibionicsLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let warmup: TimeInterval = 3600
    private let wear: TimeInterval = 14 * 24 * 3600

    private func compute(
        age: TimeInterval?,
        fault: SibionicsSensorFault.Kind? = nil,
        hasMonitor: Bool = true,
        lastReading: Date? = nil
    ) -> SibionicsSensorLifecycle {
        SibionicsSensorLifecycle.compute(
            sensorPaired: true,
            activatedAt: age.map { now.addingTimeInterval(-$0) },
            latestReadingAt: lastReading ?? now,
            hasLiveMonitor: hasMonitor,
            reportedFault: fault,
            activeDuration: wear,
            warmupDuration: warmup,
            now: now
        )
    }

    func testNoSensor() {
        XCTAssertEqual(
            SibionicsSensorLifecycle.compute(
                sensorPaired: false, activatedAt: nil, latestReadingAt: nil, hasLiveMonitor: false
            ),
            .noSensor
        )
    }

    func testWarmupThenActiveThenExpired() {
        if case let .warmup(progress, _) = compute(age: 600) {
            XCTAssertEqual(progress, 600.0 / warmup, accuracy: 0.0001)
        } else {
            XCTFail("expected warmup")
        }
        if case let .active(remaining, total) = compute(age: 4 * 3600) {
            XCTAssertEqual(total, wear)
            XCTAssertEqual(remaining, wear - 4 * 3600, accuracy: 1)
        } else {
            XCTFail("expected active")
        }
        XCTAssertEqual(compute(age: wear + 60), .expired)
    }

    func testSignalLossAfterStaleReadings() {
        XCTAssertEqual(
            compute(age: 4 * 3600, lastReading: now.addingTimeInterval(-600)),
            .signalLost(since: now.addingTimeInterval(-600))
        )
    }

    func testFaultWinsOverEverything() {
        XCTAssertEqual(compute(age: 4 * 3600, fault: .signalImplausible), .failed)
        XCTAssertEqual(compute(age: 600, fault: .signalImplausible), .failed)
    }

    func testSensorClockAgeBeatsPhoneClock() {
        // An activatedAt that is badly wrong must not affect the age when the
        // sensor's own clock is available.
        let age = SibionicsSensorLifecycle.age(
            activatedAt: now.addingTimeInterval(-99 * 86400),
            sensorAge: (elapsed: 4 * 3600, at: now),
            now: now
        )
        XCTAssertEqual(age, 4 * 3600)
    }
}
