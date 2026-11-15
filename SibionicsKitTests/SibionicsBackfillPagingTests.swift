@testable import SibionicsKit
import XCTest

/// A GS3 answers one history request with one batch and then terminates it, so
/// a single request can never cover a long gap. Backfill used to stop at the
/// first terminator, which looked like "backfill only goes back an hour".
final class SibionicsBackfillPagingTests: XCTestCase {
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SibionicsSensorMonitor.Reading] = []
        func append(_ reading: SibionicsSensorMonitor.Reading) {
            lock.lock()
            storage.append(reading)
            lock.unlock()
        }

        var readings: [SibionicsSensorMonitor.Reading] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func makeMonitor(chunkSize: Int) throws -> (SibionicsSensorMonitor, FakeSensorTransport, Collector) {
        let transport = try FakeSensorTransport()
        transport.responder = { frame in
            // Only history requests (`39 <first u16> <last u16>`). The second
            // slot is always 0 — "to the end" — because the hardware rejects a
            // bounded value.
            guard frame.cmd == SibionicsCommand.historyRecord, frame.payload.count == 4 else { return [] }
            let bytes = [UInt8](frame.payload)
            let first = Int(bytes[0]) | (Int(bytes[1]) << 8)
            let last = Int(bytes[2]) | (Int(bytes[3]) << 8)
            XCTAssertEqual(last, 0, "the sensor is only ever asked for everything to the end")
            let terminator = SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: Data([0, 0]))

            let end = first + chunkSize - 1
            var payload = Data([
                UInt8(end - first + 1),
                UInt8(first & 0xFF),
                UInt8((first >> 8) & 0xFF)
            ])
            for _ in first ... end { payload.append(Fixtures.recordData()) }
            payload.append(contentsOf: [0, 0])
            return [SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: payload), terminator]
        }

        let session = try SibionicsSession(
            transport: transport, mac: Fixtures.mac,
            firmware: SibionicsProtocolVersion(softwareRevision: "1.1.6I_V3.4.0", manufacturer: "SENSING-GNL")
        )
        let monitor = SibionicsSensorMonitor(session: session, warmup: 0, activatedAt: Date())
        let collector = Collector()
        monitor.setHandlers(
            onReading: { collector.append($0) },
            onDisconnect: {}
        )
        return (monitor, transport, collector)
    }

    func testBackfillKeepsRequestingUntilTheRangeIsCovered() async throws {
        let chunkSize = 5
        let (monitor, transport, collector) = try makeMonitor(chunkSize: chunkSize)
        try await monitor.session.start()

        // One hour of records in 5-record batches: the sensor terminates each
        // batch, so this needs twelve requests rather than one.
        try await monitor.requestHistory(from: 1, to: 60)

        XCTAssertEqual(collector.readings.count, 60, "every record in the range must arrive")
        XCTAssertEqual(collector.readings.map(\.record.index), Array(UInt16(1) ... UInt16(60)))

        let requests = transport.writtenFrames.filter { $0.cmd == SibionicsCommand.historyRequest }.count
        XCTAssertEqual(requests, 12, "one request per chunk, not one for the whole range")
    }

    func testBackfillStopsWhenTheSensorHasNothingMore() async throws {
        // A whole range that fits one packet: 15 records is the most a 256-byte
        // frame can carry.
        let (monitor, transport, collector) = try makeMonitor(chunkSize: 15)
        try await monitor.session.start()
        try await monitor.requestHistory(from: 1, to: 12)

        XCTAssertEqual(collector.readings.count, 12)
        XCTAssertEqual(
            transport.writtenFrames.filter { $0.cmd == SibionicsCommand.historyRequest }.count, 1,
            "the sensor answered the whole range at once"
        )
    }

    /// A sensor that always answers with the same chunk must not be asked
    /// forever.
    func testBackfillGivesUpWhenTheSensorRepeatsItself() async throws {
        let transport = try FakeSensorTransport()
        transport.responder = { frame in
            guard frame.cmd == SibionicsCommand.historyRecord, frame.payload.count == 4 else { return [] }
            // Always the same five records, whatever was asked for.
            var payload = Data([5, 1, 0])
            for _ in 0 ..< 5 { payload.append(Fixtures.recordData()) }
            payload.append(contentsOf: [0, 0])
            return [
                SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: payload),
                SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: Data([0, 0]))
            ]
        }
        let session = try SibionicsSession(
            transport: transport, mac: Fixtures.mac,
            firmware: SibionicsProtocolVersion(softwareRevision: "x_V3.4.0", manufacturer: "SENSING-GNL")
        )
        let monitor = SibionicsSensorMonitor(session: session, warmup: 0, activatedAt: Date())
        monitor.setHandlers(onReading: { _ in }, onDisconnect: {})
        try await session.start()

        let started = Date()
        try await monitor.requestHistory(from: 1, to: 500)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20, "must not spin")

        let requests = transport.writtenFrames.filter { $0.cmd == SibionicsCommand.historyRequest }.count
        XCTAssertLessThanOrEqual(requests, 3, "no progress means stop")
    }
}
