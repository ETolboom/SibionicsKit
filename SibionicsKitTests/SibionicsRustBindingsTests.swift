@testable import SibionicsKit
import XCTest

/// The Swift side of the Rust driver: the bindings, and the behaviour this kit
/// used to implement in Swift, now provided by `cgm-sibionics`. The protocol
/// itself is tested in Rust (capture vectors, engine, simulator, e2e).
final class SibionicsRustBindingsTests: XCTestCase {
    // MARK: - NFC (was SibionicsNFCTests)

    private let older = "GJ,GS3*-BEABMA,GNL,AAC25B18AAFZ,E2AFF9F01F19,PG291,HT"

    func testParsesTheDocumentedRecord() throws {
        let record = try XCTUnwrap(SibionicsNFCRecord(raw: older))
        XCTAssertEqual(record.fields.count, 7)
        XCTAssertEqual(record.model, "GS3*-BEABMA")
        XCTAssertEqual(record.regionCode, "GNL")
        XCTAssertEqual(record.mac, "E2:AF:F9:F0:1F:19")
        XCTAssertEqual(record.serial, "AAC25B18AAFZ")
        XCTAssertEqual(record.bleNameSuffix, "BEABMA")
        XCTAssertEqual(record.appPrefix, "GJ")
    }

    func testParsesACurrentTag() throws {
        let record = try XCTUnwrap(SibionicsNFCRecord(raw: "GJ,04ES126090500NA,6,10943L\n"))
        XCTAssertEqual(record.serial, "04ES126090500NA")
        XCTAssertNil(record.mac, "a GS3 tag carries no MAC")
        XCTAssertEqual(record.raw, "GJ,04ES126090500NA,6,10943L")
    }

    func testChinaRegionAndNonRecords() throws {
        let record = try XCTUnwrap(SibionicsNFCRecord(raw: "GJ,GS3*-XXXXXX,CN,AABBCCDDEEFF,112233445566"))
        XCTAssertEqual(record.regionCode, "CN")
        XCTAssertEqual(record.mac, "AA:BB:CC:DD:EE:FF")
        XCTAssertNil(SibionicsNFCRecord(raw: ""))
        XCTAssertNil(SibionicsNFCRecord(raw: "nonsense"))
        XCTAssertNil(SibionicsNFCRecord(raw: "a,b"))
    }

    // MARK: - Account id (was SibionicsAccountIDTests)

    func testAccountIDsAreValidatedByTheDriver() {
        XCTAssertNoThrow(try SibionicsAccount.validate("2121771491330663241"))
        XCTAssertNoThrow(try SibionicsAccount.validate("abc-123"), "non-numeric ids take the hash path")
        XCTAssertThrowsError(try SibionicsAccount.validate("   "))
        XCTAssertThrowsError(try SibionicsAccount.validate("18446744073709551616"), "does not fit a UInt64")
    }

    // MARK: - Driver description

    func testVariantsFollowTheRegistrationKey() {
        XCTAssertEqual(variants().map(\.id), ["gs3", "gs3-ru", "gs3-sensing"])
        XCTAssertEqual(advertisedService().count, 16)
        XCTAssertFalse(driverVersion().isEmpty)
    }

    func testAddressesAreStablePerPeripheral() {
        let id = UUID()
        XCTAssertEqual(SibionicsRustHost.address(for: id), SibionicsRustHost.address(for: id))
        XCTAssertEqual(SibionicsRustHost.address(for: id).count, 6)
    }

    // MARK: - Engine through the bindings

    func testAFreshEngineLoadsUnpairedAndRefusesCommands() throws {
        let engine = try SibionicsEngine(variant: "gs3", utcOffsetSecs: 0)
        XCTAssertThrowsError(try SibionicsEngine(variant: "nope", utcOffsetSecs: 0))
        guard case let .load(id, .session)? = engine.pollAction() else {
            return XCTFail("the engine loads its session first")
        }
        XCTAssertNil(engine.pollAction(), "one action outstanding at a time (E1)")
        XCTAssertThrowsError(try engine.handleCompletion(id: id &+ 1, completion: .stored))
        try engine.handleCompletion(id: id, completion: .loaded(bytes: nil))
        XCTAssertEqual(engine.state(), .unpaired)
        let status = try engine.submit(command: .status)
        var outcomes: [FfiOutcome] = []
        while let event = engine.pollEvent() {
            if case let .finished(done, outcome) = event, done == status { outcomes.append(outcome) }
        }
        guard case .refused(.notPaired)? = outcomes.first else {
            return XCTFail("\(outcomes)")
        }
    }

    func testPairingIssuesAConnectToTheGivenAddress() throws {
        let engine = try SibionicsEngine(variant: "gs3", utcOffsetSecs: 0)
        guard case let .load(load, _)? = engine.pollAction() else { return XCTFail() }
        try engine.handleCompletion(id: load, completion: .loaded(bytes: nil))
        let address = SibionicsRustHost.address(for: UUID())
        _ = try engine.submit(command: .pair(
            address: address, credential: nil, expectedSerial: nil, knownActivationMs: nil
        ))
        guard case let .ble(_, .connect(connectTo))? = engine.pollAction() else {
            return XCTFail("pairing starts with a connect")
        }
        XCTAssertEqual(connectTo, address)
    }
}
