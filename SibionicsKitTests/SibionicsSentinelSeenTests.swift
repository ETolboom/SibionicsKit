@testable import SibionicsKit
import XCTest

/// The sensor sends four records with no result (`0xFF01`) for every one that
/// carries a value. They are not readings, but they do occupy real minute
/// indices — and they used to advance nothing at all, so the next real value
/// looked like it had skipped four minutes. The gap detector then asked the
/// sensor for them and got `01 00` back, which is where 132 of the failed
/// history requests in one nine-hour log came from.
final class SibionicsSentinelSeenTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(UInt16, Bool)] = []
        private var readings: [UInt16] = []
        func recordSeen(_ index: UInt16, _ isHistorical: Bool) {
            lock.lock(); seen.append((index, isHistorical)); lock.unlock()
        }

        func reading(_ index: UInt16) {
            lock.lock(); readings.append(index); lock.unlock()
        }

        var seenIndices: [UInt16] { lock.lock(); defer { lock.unlock() }; return seen.map(\.0) }
        var readingIndices: [UInt16] { lock.lock(); defer { lock.unlock() }; return readings }
    }

    func testNoResultRecordsAreReportedAsSeen() async throws {
        let transport = try FakeSensorTransport()
        let session = try SibionicsSession(
            transport: transport, mac: Fixtures.mac,
            firmware: SibionicsProtocolVersion(softwareRevision: "1.1.6I_V3.4.0", manufacturer: "SENSING-GNL")
        )
        let monitor = SibionicsSensorMonitor(session: session, warmup: 0, activatedAt: Date())
        let collector = Collector()
        monitor.setHandlers(
            onReading: { collector.reading($0.record.index) },
            onDisconnect: {},
            onRecordSeen: { index, isHistorical in collector.recordSeen(index, isHistorical) }
        )
        // `run` is what consumes the record stream; the clock probe is skipped
        // because an activation time is already set.
        Task { await monitor.run(historyFrom: nil) }
        await transport.waitForSubscriber()

        // One real value followed by four sentinels: the shape the sensor
        // actually sends on the one-minute grid.
        let payload = Fixtures.glucosePayload(
            cmd: SibionicsCommand.liveRecord,
            startIndex: 100,
            records: [
                Fixtures.recordData(glucoseRaw: 57),
                Fixtures.recordData(glucoseRaw: SibionicsRecord.glucoseNoResult),
                Fixtures.recordData(glucoseRaw: SibionicsRecord.glucoseNoResult),
                Fixtures.recordData(glucoseRaw: SibionicsRecord.glucoseNoResult),
                Fixtures.recordData(glucoseRaw: SibionicsRecord.glucoseNoResult)
            ]
        )
        try transport.push(SibionicsFrame(cmd: SibionicsCommand.liveRecord, payload: payload))

        let deadline = Date().addingTimeInterval(2)
        while collector.seenIndices.count < 5, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(collector.seenIndices, [100, 101, 102, 103, 104], "every index the sensor sent, value or not")
        XCTAssertEqual(collector.readingIndices, [100], "only the one with a value becomes a reading")
        session.close()
    }
}
