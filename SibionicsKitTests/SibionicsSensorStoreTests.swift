@testable import SibionicsKit
import XCTest

/// The previous sensor keeps what it was and how it ended.
final class SibionicsSensorStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ mac: String, pairedAt: Date? = nil) -> SibionicsSensorRecord {
        SibionicsSensorRecord(
            deviceInfo: SibionicsDeviceInfo(
                mac: mac,
                model: "GS3",
                serial: nil,
                softwareRevision: "1.1.6I_V3.4.0",
                protocolGeneration: .v3,
                region: SibionicsProtocolVersion(softwareRevision: "1.1.6I_V3.4.0", manufacturer: "").region,
                warmup: SibionicsDeviceInfo.defaultWarmup,
                activeDuration: SibionicsDeviceInfo.defaultActiveDuration
            ),
            serial: "SN-\(mac)",
            pairedAt: pairedAt
        )
    }

    func testNoPreviousSensorWithOnlyTheActiveOne() {
        var store = SibionicsSensorStore()
        store.adopt(record("A"), at: t0)
        XCTAssertNil(store.previous)
    }

    func testPairingADifferentSensorMarksTheOldOneReplaced() {
        var store = SibionicsSensorStore()
        store.adopt(record("A", pairedAt: t0), at: t0)
        let t1 = t0.addingTimeInterval(14 * 86400)
        store.adopt(record("B", pairedAt: t1), at: t1)

        XCTAssertEqual(store.active?.id, "B")
        XCTAssertEqual(store.previous?.id, "A")
        XCTAssertEqual(store.previous?.endReason, .replaced)
        XCTAssertEqual(store.previous?.endedAt, t1)
        XCTAssertEqual(store.previous?.pairedAt, t0)
        XCTAssertNil(store.active?.endedAt)
    }

    func testEndingTheSensorKeepsItAsPrevious() {
        var store = SibionicsSensorStore()
        store.adopt(record("A"), at: t0)
        let t1 = t0.addingTimeInterval(3600)
        store.discardActive(reason: .failed, at: t1)

        XCTAssertNil(store.active)
        XCTAssertEqual(store.previous?.id, "A")
        XCTAssertEqual(store.previous?.endReason, .failed)
        XCTAssertEqual(store.previous?.endedAt, t1)
    }

    /// Ending and pairing the same sensor again makes it active again, with
    /// its first pairing date, and it is no longer "previous".
    func testPairingTheSameSensorAgainReactivatesIt() {
        var store = SibionicsSensorStore()
        store.adopt(record("A", pairedAt: t0), at: t0)
        store.discardActive(at: t0.addingTimeInterval(60))
        let t2 = t0.addingTimeInterval(120)
        store.adopt(record("A", pairedAt: t2), at: t2)

        XCTAssertEqual(store.active?.id, "A")
        XCTAssertEqual(store.active?.pairedAt, t0)
        XCTAssertNil(store.active?.endedAt)
        XCTAssertNil(store.active?.endReason)
        XCTAssertNil(store.previous)
    }

    func testEndDetailsSurviveARoundTrip() {
        var store = SibionicsSensorStore()
        store.adopt(record("A", pairedAt: t0), at: t0)
        store.adopt(record("B"), at: t0.addingTimeInterval(60))

        let restored = SibionicsSensorStore(rawValue: store.rawValue)
        XCTAssertEqual(restored?.previous?.endReason, .replaced)
        XCTAssertEqual(restored?.previous?.endedAt, t0.addingTimeInterval(60))
        XCTAssertEqual(restored?.previous?.pairedAt, t0)
    }
}
