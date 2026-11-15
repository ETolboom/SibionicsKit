@testable import SibionicsKit
import XCTest

final class SibionicsRecordTests: XCTestCase {
    func testRecordFieldDecode() throws {
        let record = try XCTUnwrap(SibionicsRecord(Fixtures.recordData(), index: 42))
        XCTAssertEqual(record.index, 42)
        XCTAssertEqual(record.temperatureRaw, 2650)
        XCTAssertEqual(record.dumpRaw, 7)
        XCTAssertEqual(record.currentRaw, 1234)
        XCTAssertEqual(record.displayGlucoseRaw, 57)
        XCTAssertEqual(record.glucoseMmolL ?? -1, 5.7, accuracy: 0.0001)
        XCTAssertEqual(record.trendBits, 3)
        XCTAssertFalse(record.presentCState)
        XCTAssertEqual(record.algorithmCState, 5)
        XCTAssertEqual(record.tstate, 2)
        XCTAssertEqual(record.dstate, 1)
        XCTAssertEqual(record.ceVoltageRaw, 1500)
        XCTAssertEqual(record.reVoltageRaw, 900)
        XCTAssertEqual(record.algorithmGlucose(), 6.0, accuracy: 0.0001)
    }

    func testSentinelMeansNoResult() throws {
        let record = try XCTUnwrap(SibionicsRecord(Fixtures.recordData(glucoseRaw: 0xFF01), index: 0))
        XCTAssertFalse(record.hasGlucose)
        XCTAssertNil(record.glucoseMmolL)
        XCTAssertNil(record.glucoseMgDL)
    }

    func testAnythingAtOrAboveSentinelFloorHasNoResult() {
        for raw in [UInt16(0xFF00), 0xFF01, 0xFFFF] {
            let record = SibionicsRecord(Fixtures.recordData(glucoseRaw: raw), index: 0)
            XCTAssertFalse(record?.hasGlucose ?? true, "0x\(String(raw, radix: 16)) should be a sentinel")
        }
        // 0xFEFF is the highest usable value.
        XCTAssertTrue(SibionicsRecord(Fixtures.recordData(glucoseRaw: 0xFEFF), index: 0)?.hasGlucose ?? false)
    }

    func testPresentCStateBit() throws {
        let record = try XCTUnwrap(SibionicsRecord(Fixtures.recordData(presentCState: true), index: 0))
        XCTAssertTrue(record.presentCState)
    }

    func testShortRecordIsRejected() {
        XCTAssertNil(SibionicsRecord(Data(repeating: 0, count: 15), index: 0))
    }

    func testGlucosePacketDecode() throws {
        let payload = Fixtures.glucosePayload(
            cmd: SibionicsCommand.historyRecord,
            startIndex: 100,
            records: [Fixtures.recordData(), Fixtures.recordData(glucoseRaw: 61)],
            tail: 0x1234
        )
        let packet = try XCTUnwrap(SibionicsGlucosePacket(cmd: SibionicsCommand.historyRecord, payload: payload))
        XCTAssertEqual(packet.kind, .history)
        XCTAssertEqual(packet.startIndex, 100)
        XCTAssertEqual(packet.records.map(\.index), [100, 101])
        XCTAssertEqual(packet.tail, 0x1234)
        XCTAssertFalse(packet.isEmptyHistoryTerminator)
    }

    func testEmptyHistoryTerminator() throws {
        let payload = Fixtures.glucosePayload(cmd: SibionicsCommand.historyRecord, startIndex: 0, records: [])
        let packet = try XCTUnwrap(SibionicsGlucosePacket(cmd: SibionicsCommand.historyRecord, payload: payload))
        XCTAssertTrue(packet.records.isEmpty)
        XCTAssertTrue(packet.isEmptyHistoryTerminator)
    }

    /// A packet that claims more records than it carries must yield only the
    /// records actually present instead of reading past the buffer.
    func testTruncatedRecordListStopsAtTheBufferEnd() throws {
        var payload = Data([5, 10, 0])
        payload.append(Fixtures.recordData())
        let packet = try XCTUnwrap(SibionicsGlucosePacket(cmd: SibionicsCommand.liveRecord, payload: payload))
        XCTAssertEqual(packet.records.count, 1)
        XCTAssertNil(packet.tail)
    }
}
