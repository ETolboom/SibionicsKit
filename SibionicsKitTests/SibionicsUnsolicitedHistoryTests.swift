@testable import SibionicsKit
import XCTest

/// `ff31` is shared with every app connected to the sensor, and a `0x39` reply
/// carries no request id. On 2026-11-18 the official app synced while we were
/// connected: its two refused requests showed up as our warnings, and its
/// ~1,200-record batch was forwarded down our *live* path as day-old
/// "realtime" readings. History is now only accepted while a request of ours
/// is open, and only when it continues where our batch left off.
final class SibionicsUnsolicitedHistoryTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SibionicsSensorMonitor.Reading] = []
        func append(_ reading: SibionicsSensorMonitor.Reading) {
            lock.lock(); storage.append(reading); lock.unlock()
        }

        var readings: [SibionicsSensorMonitor.Reading] {
            lock.lock(); defer { lock.unlock() }; return storage
        }
    }

    private static let firmware = SibionicsProtocolVersion(
        softwareRevision: "1.1.6I_V3.4.0", manufacturer: "SENSING-GNL"
    )

    private static func historyPacket(from start: UInt16, count: Int) -> SibionicsFrame {
        SibionicsFrame(
            cmd: SibionicsCommand.historyRecord,
            payload: Fixtures.glucosePayload(
                cmd: SibionicsCommand.historyRecord, startIndex: start,
                records: Array(repeating: Fixtures.recordData(), count: count), tail: 0
            )
        )
    }

    private static func livePacket(_ index: UInt16) -> SibionicsFrame {
        SibionicsFrame(
            cmd: SibionicsCommand.liveRecord,
            payload: Fixtures.glucosePayload(
                cmd: SibionicsCommand.liveRecord, startIndex: index, records: [Fixtures.recordData()]
            )
        )
    }

    private static let terminator = SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: Data([0x00, 0x05]))
    private static let refusal = SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: Data([0x01, 0x00]))

    private func makeMonitor(
        responder: (@Sendable(SibionicsFrame) -> [SibionicsFrame])? = nil
    ) throws -> (SibionicsSensorMonitor, FakeSensorTransport, Collector) {
        let transport = try FakeSensorTransport()
        transport.responder = responder
        let session = try SibionicsSession(transport: transport, mac: Fixtures.mac, firmware: Self.firmware)
        session.historyIdleTimeout = 1
        let monitor = SibionicsSensorMonitor(session: session, warmup: 0, activatedAt: Date())
        let collector = Collector()
        monitor.setHandlers(onReading: { collector.append($0) }, onDisconnect: {})
        return (monitor, transport, collector)
    }

    private func waitFor(
        _ collector: Collector, timeout: TimeInterval = 2, _ condition: ([SibionicsSensorMonitor.Reading]) -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition(collector.readings) {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testUnsolicitedHistoryNeverReachesTheLivePath() async throws {
        let (monitor, transport, collector) = try makeMonitor()
        await monitor.run(historyFrom: nil)

        // Another app's sync: yesterday's records, no request of ours open.
        try transport.push(Self.historyPacket(from: 3991, count: 15))
        try transport.push(Self.historyPacket(from: 4006, count: 15))
        try transport.push(Self.refusal)
        // Then the next live record, which must be the only reading.
        try transport.push(Self.livePacket(5230))

        await waitFor(collector) { $0.contains { $0.record.index == 5230 } }
        XCTAssertEqual(collector.readings.map(\.record.index), [5230])
        XCTAssertEqual(collector.readings.map(\.isHistorical), [false])
    }

    func testOurMultiPacketBatchIsDeliveredOnceAndAsHistory() async throws {
        let (monitor, _, collector) = try makeMonitor { frame in
            guard frame.cmd == SibionicsCommand.historyRequest, frame.payload.count == 4 else { return [] }
            let first = UInt16(frame.payload[frame.payload.startIndex])
                | UInt16(frame.payload[frame.payload.startIndex + 1]) << 8
            guard first == 1 else { return [Self.terminator] }
            return [Self.historyPacket(from: 1, count: 5), Self.historyPacket(from: 6, count: 5), Self.terminator]
        }
        await monitor.run(historyFrom: nil)
        try await monitor.requestHistory(from: 1, to: 10)

        // Packets after the first used to be forwarded down the live path as
        // well, so they arrived twice: once as backfill, once as realtime.
        XCTAssertEqual(collector.readings.map(\.record.index), Array(UInt16(1) ... 10))
        XCTAssertTrue(collector.readings.allSatisfy(\.isHistorical))
    }

    func testForeignPacketInsideOurBatchIsDropped() async throws {
        let (monitor, _, collector) = try makeMonitor { frame in
            guard frame.cmd == SibionicsCommand.historyRequest, frame.payload.count == 4 else { return [] }
            let first = UInt16(frame.payload[frame.payload.startIndex])
                | UInt16(frame.payload[frame.payload.startIndex + 1]) << 8
            guard first == 1 else { return [Self.terminator] }
            // The official app's batch interleaves with ours.
            return [Self.historyPacket(from: 1, count: 5), Self.historyPacket(from: 3991, count: 5), Self.historyPacket(from: 6, count: 5), Self.terminator]
        }
        await monitor.run(historyFrom: nil)
        try await monitor.requestHistory(from: 1, to: 10)

        XCTAssertEqual(collector.readings.map(\.record.index), Array(UInt16(1) ... 10))
    }

    func testUnsolicitedAckDoesNotEndOurNextBatch() async throws {
        let (monitor, transport, collector) = try makeMonitor { frame in
            guard frame.cmd == SibionicsCommand.historyRequest else { return [] }
            return [Self.historyPacket(from: 1, count: 5), Self.historyPacket(from: 6, count: 5), Self.terminator]
        }
        await monitor.run(historyFrom: nil)
        // Another app's refused request arrives while we are idle. It used to be
        // buffered as a batch end, which then cut our next batch short.
        try transport.push(Self.refusal)
        try transport.push(Self.livePacket(20))
        await waitFor(collector) { !$0.isEmpty }

        try await monitor.requestHistory(from: 1, to: 10)
        XCTAssertEqual(
            collector.readings.filter(\.isHistorical).map(\.record.index), Array(UInt16(1) ... 10)
        )
    }
}
