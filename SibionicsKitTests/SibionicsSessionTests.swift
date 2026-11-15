import CoreBluetooth
@testable import SibionicsKit
import XCTest

/// A transport that behaves like a sensor: it decrypts what we write, hands the
/// frame to a responder, and encrypts the reply back onto the notify stream.
/// Using the real cipher here means the tests also cover the seal/open boundary.
final class FakeSensorTransport: SibionicsGATTTransport, @unchecked Sendable {
    let peripheralID = UUID()
    let name: String? = "GS3-FAKE"

    private let cipher: SibionicsCipher
    private let queue = DispatchQueue(label: "fake.sensor")
    private var continuation: AsyncStream<Data>.Continuation?
    private var streamOpened: CheckedContinuation<Void, Never>?

    /// Returns the plaintext replies to send back. Called on the transport queue.
    var responder: (@Sendable(SibionicsFrame) -> [SibionicsFrame])?
    private(set) var writtenFrames: [SibionicsFrame] = []
    private(set) var wroteNotificationEnable = false
    /// Ordered record of "enable" and "write", for asserting the subscription
    /// is live before anything is transmitted.
    private(set) var events: [String] = []

    init(mac: String = Fixtures.mac) throws {
        cipher = try SibionicsCipher(mac: mac)
    }

    func read(_: CBUUID) async throws -> Data {
        Data()
    }

    func write(_ data: Data, to _: CBUUID, withResponse _: Bool) async throws {
        let plaintext = try cipher.apply(data)
        guard let frame = try? SibionicsFrame(decoding: plaintext) else {
            XCTFail("the driver wrote something that is not a valid frame: \(plaintext.hexString)")
            return
        }
        queue.sync {
            writtenFrames.append(frame)
            events.append("write")
        }
        let replies = responder?(frame) ?? []
        for reply in replies {
            let sealed = try cipher.apply(reply.encoded)
            queue.async { self.continuation?.yield(sealed) }
        }
    }

    func subscribe(_: CBUUID) async throws -> AsyncStream<Data> {
        let stream = AsyncStream<Data> { continuation in
            queue.async {
                self.continuation = continuation
                self.wroteNotificationEnable = true
                self.events.append("enable")
                self.streamOpened?.resume()
                self.streamOpened = nil
            }
        }
        // Mimic the real transport: do not return until the subscription is live.
        await waitForSubscriber()
        return stream
    }

    func disconnect() {
        queue.async { self.continuation?.finish() }
    }

    /// Waits until the session has subscribed, so a reply cannot be yielded
    /// before anybody is listening.
    func waitForSubscriber() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if self.continuation != nil { continuation.resume() }
                else { self.streamOpened = continuation }
            }
        }
    }

    /// Pushes an unsolicited packet (a live record, say).
    func push(_ frame: SibionicsFrame) throws {
        let sealed = try cipher.apply(frame.encoded)
        queue.async { self.continuation?.yield(sealed) }
    }

    var lastFrame: SibionicsFrame? { queue.sync { writtenFrames.last } }
}

final class SibionicsSessionTests: XCTestCase {
    private func makeSession(
        responder: @escaping @Sendable(SibionicsFrame) -> [SibionicsFrame] = { _ in [] }
    ) throws -> (SibionicsSession, FakeSensorTransport) {
        let transport = try FakeSensorTransport()
        transport.responder = responder
        let session = try SibionicsSession(
            transport: transport,
            mac: Fixtures.mac,
            firmware: SibionicsProtocolVersion(softwareRevision: "x_V3.1", manufacturer: "GNL")
        )
        session.requestTimeout = 0.4
        session.historyTimeout = 0.4
        return (session, transport)
    }

    func testAuthSendsTheDocumentedFrame() async throws {
        let (session, transport) = try makeSession { _ in
            [SibionicsFrame(cmd: SibionicsCommand.auth, payload: Data([0x01, 0x00]))]
        }
        try await session.start()
        await transport.waitForSubscriber()

        let reply = try await session.authenticate(
            registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
        )
        XCTAssertEqual(reply.cmd, SibionicsCommand.auth)
        XCTAssertEqual(transport.lastFrame?.encoded, Fixtures.authFramePlaintext)
    }

    /// A refusal must be an error, not a warning: the next thing the driver
    /// would do is write an activation command.
    func testAuthRefusalIsAnError() async throws {
        let (session, transport) = try makeSession { _ in
            [SibionicsFrame(cmd: SibionicsCommand.auth, payload: Data([0x02, 0x00]))]
        }
        try await session.start()
        await transport.waitForSubscriber()

        do {
            _ = try await session.authenticate(
                registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
            )
            XCTFail("expected the refusal to throw")
        } catch let error as SibionicsSession.SessionError {
            guard case let .authenticationRejected(status) = error else {
                return XCTFail("unexpected \(error)")
            }
            XCTAssertEqual(status, 0x02)
        }
        // Only the auth frame was written.
        XCTAssertEqual(transport.writtenFrames.count, 1)
        session.close()
    }

    func testAuthAcceptsStatusOne() async throws {
        let (session, transport) = try makeSession { _ in
            [SibionicsFrame(cmd: SibionicsCommand.auth, payload: Data([0x01, 0x00]))]
        }
        try await session.start()
        await transport.waitForSubscriber()
        let reply = try await session.authenticate(
            registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
        )
        XCTAssertEqual(reply.status, 0x01)
    }

    func testBootstrapFrameSurfacesAsUnauthenticated() async throws {
        let transport = try FakeSensorTransport()
        let session = try SibionicsSession(
            transport: transport, mac: Fixtures.mac,
            firmware: SibionicsProtocolVersion(softwareRevision: "x_V3.1", manufacturer: "GNL")
        )
        session.requestTimeout = 0.4
        try await session.start()
        await transport.waitForSubscriber()

        // A sensor with no session answers even a valid auth with this.
        transport.responder = { _ in [] }
        let sealed = try SibionicsCipher(mac: Fixtures.mac).apply(SibionicsReply.unauthenticatedBootstrap)
        transport.pushRaw(sealed)
        try await Task.sleep(nanoseconds: 120_000_000)

        do {
            _ = try await session.deviceTime()
            XCTFail("expected the bootstrap frame to fail the request")
        } catch let error as SibionicsSession.SessionError {
            switch error {
            case .timeout,
                 .unauthenticated: break
            default: XCTFail("unexpected error \(error)")
            }
        }
        session.close()
    }

    func testDeviceTimeParsing() async throws {
        let activation: UInt32 = 1_700_000_000
        let current = activation + 3600
        let (session, transport) = try makeSession { frame in
            guard frame.cmd == SibionicsCommand.infoQuery, frame.payload.first == SibionicsCommand.infoDeviceTime else {
                return []
            }
            let payload = Fixtures.deviceTimePayload(
                activation: activation, current: current, last: current - 30, lastIndex: 60
            )
            return [SibionicsFrame(cmd: SibionicsCommand.infoQuery, payload: payload)]
        }
        try await session.start()
        await transport.waitForSubscriber()

        let time = try await session.deviceTime()
        XCTAssertTrue(time.isActivated)
        XCTAssertEqual(time.activation, activation)
        XCTAssertEqual(time.current, current)
        XCTAssertEqual(time.lastIndex, 60)
        XCTAssertEqual(time.elapsedSeconds, 3600)
        XCTAssertEqual(time.activationDate, Date(timeIntervalSince1970: TimeInterval(activation)))
    }

    func testDeviceTimeRejectsShortPayload() {
        XCTAssertThrowsError(try SibionicsSession.parseDeviceTime(Data(repeating: 0, count: 13)))
    }

    func testActivationUsesOpcode35AndCarriesAccount() async throws {
        let (session, transport) = try makeSession { _ in [] }
        try await session.start()
        await transport.waitForSubscriber()

        // Answer with the real ack shape: `01 00 <time LE>`.
        transport.responder = { frame in
            guard frame.cmd == SibionicsCommand.activateBindIn else { return [] }
            var payload = Data([0x01, 0x00])
            payload.append(contentsOf: Fixtures.le32(Fixtures.activationTimestamp))
            return [SibionicsFrame(cmd: SibionicsCommand.activateBindIn, payload: payload)]
        }
        let ack = try await session.activateBindIn(
            activationTime: Date(timeIntervalSince1970: TimeInterval(Fixtures.activationTimestamp)),
            accountID: try Fixtures.account()
        )
        XCTAssertTrue(ack.isSuccess)
        XCTAssertEqual(ack.timestamp, Fixtures.activationTimestamp)

        let frame = try XCTUnwrap(transport.lastFrame)
        XCTAssertEqual(frame.cmd, 0x35)
        XCTAssertEqual(frame.encoded[0], 0x12)
        XCTAssertEqual(Data(frame.payload.suffix(12)), Fixtures.accountBytes)
    }

    /// An ack that does not echo our timestamp means the sensor did not take the
    /// activation; reporting success there would be the worst outcome.
    func testActivationRejectsAMismatchedEcho() async throws {
        let (session, transport) = try makeSession { _ in [] }
        try await session.start()
        await transport.waitForSubscriber()
        transport.responder = { frame in
            guard frame.cmd == SibionicsCommand.activateBindIn else { return [] }
            var payload = Data([0x01, 0x00])
            payload.append(contentsOf: Fixtures.le32(Fixtures.activationTimestamp &+ 5))
            return [SibionicsFrame(cmd: SibionicsCommand.activateBindIn, payload: payload)]
        }
        do {
            _ = try await session.activateBindIn(
                activationTime: Date(timeIntervalSince1970: TimeInterval(Fixtures.activationTimestamp)),
                accountID: try Fixtures.account()
            )
            XCTFail("expected the mismatched echo to throw")
        } catch let error as SibionicsSession.SessionError {
            guard case .rejected = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testActivationRejectsANonSuccessStatus() async throws {
        let (session, transport) = try makeSession { _ in [] }
        try await session.start()
        await transport.waitForSubscriber()
        transport.responder = { frame in
            guard frame.cmd == SibionicsCommand.activateBindIn else { return [] }
            var payload = Data([0x02, 0x00])
            payload.append(contentsOf: Fixtures.le32(Fixtures.activationTimestamp))
            return [SibionicsFrame(cmd: SibionicsCommand.activateBindIn, payload: payload)]
        }
        do {
            _ = try await session.activateBindIn(
                activationTime: Date(timeIntervalSince1970: TimeInterval(Fixtures.activationTimestamp)),
                accountID: try Fixtures.account()
            )
            XCTFail("expected a non-success status to throw")
        } catch let error as SibionicsSession.SessionError {
            guard case .rejected = error else { return XCTFail("unexpected \(error)") }
        }
    }

    /// Regression: the pairing service used to authenticate before anyone was
    /// subscribed to `ff31`, so the reply was dropped and the request looked
    /// like a 10 s timeout. It must fail loudly instead.
    func testSendingWithoutStartingFailsImmediately() async throws {
        let (session, _) = try makeSession { _ in [] }
        do {
            _ = try await session.authenticate(
                registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
            )
            XCTFail("expected an immediate notSubscribed error")
        } catch let error as SibionicsSession.SessionError {
            guard case .notSubscribed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    /// And the fix itself: after `start()` the same call reaches the sensor.
    func testStartingAllowsTheRequestToBeAnswered() async throws {
        let (session, transport) = try makeSession { _ in
            [SibionicsFrame(cmd: SibionicsCommand.auth, payload: Data([0x01, 0x00]))]
        }
        try await session.start()
        await transport.waitForSubscriber()
        let reply = try await session.authenticate(
            registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
        )
        XCTAssertEqual(reply.status, 0x01)
        session.close()
    }

    /// The subscription must be acknowledged before the first frame goes out,
    /// otherwise the reply lands in the gap and is dropped.
    func testSubscriptionIsLiveBeforeAnythingIsWritten() async throws {
        let (session, transport) = try makeSession { _ in
            [SibionicsFrame(cmd: SibionicsCommand.auth, payload: Data([0x01, 0x00]))]
        }
        try await session.start()
        _ = try await session.authenticate(
            registrationKey: Fixtures.registrationKey, accountID: try Fixtures.account()
        )
        XCTAssertEqual(transport.events, ["enable", "write"])
        session.close()
    }

    func testTimeoutWhenTheSensorStaysSilent() async throws {
        let (session, transport) = try makeSession { _ in [] }
        try await session.start()
        await transport.waitForSubscriber()
        do {
            _ = try await session.deviceTime()
            XCTFail("expected a timeout")
        } catch let error as SibionicsSession.SessionError {
            guard case .timeout = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testLiveRecordReachesTheRecordStream() async throws {
        let (session, transport) = try makeSession { _ in [] }
        try await session.start()
        await transport.waitForSubscriber()

        let payload = Fixtures.glucosePayload(
            cmd: SibionicsCommand.liveRecord, startIndex: 7, records: [Fixtures.recordData()]
        )
        let expectation = expectation(description: "record")
        let consumer = Task {
            for await record in session.records() {
                XCTAssertEqual(record.index, 7)
                XCTAssertEqual(record.glucoseMmolL ?? 0, 5.7, accuracy: 0.0001)
                expectation.fulfill()
                break
            }
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        try transport.push(SibionicsFrame(cmd: SibionicsCommand.liveRecord, payload: payload))
        await fulfillment(of: [expectation], timeout: 2)
        consumer.cancel()
        session.close()
    }

    func testHistoryReturnsFirstPacketThenStreamsTheRest() async throws {
        // A real batch arrives without further writes: the sensor answers one
        // request with as many packets as it needs and then an empty terminator.
        let (session, transport) = try makeSession { frame in
            guard frame.cmd == SibionicsCommand.historyRequest else { return [] }
            let first = Fixtures.glucosePayload(
                cmd: SibionicsCommand.historyRecord, startIndex: 10,
                records: [Fixtures.recordData()]
            )
            let second = Fixtures.glucosePayload(
                cmd: SibionicsCommand.historyRecord, startIndex: 11,
                records: [Fixtures.recordData(glucoseRaw: 61)]
            )
            let end = Fixtures.glucosePayload(
                cmd: SibionicsCommand.historyRecord, startIndex: 0, records: []
            )
            return [
                SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: first),
                SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: second),
                SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: end)
            ]
        }
        try await session.start()
        await transport.waitForSubscriber()

        let first = try await session.requestHistory(from: 10, to: 12)
        XCTAssertEqual(first.startIndex, 10)
        XCTAssertEqual(first.records.count, 1)

        var events: [SibionicsSession.HistoryEvent] = []
        for await event in session.historyEvents() {
            events.append(event)
            if event == .batchEnd { break }
        }
        XCTAssertEqual(events.count, 2, "one record packet and then the terminator")
        if case let .packet(packet) = events[0] {
            XCTAssertEqual(packet.startIndex, 11)
        } else {
            XCTFail("expected a packet first")
        }
        XCTAssertEqual(events.last, .batchEnd)
        session.close()
    }

    func testUnparseableHistoryReplyEndsTheBatchInsteadOfFailing() async throws {
        // Observed on hardware: the sensor sometimes answers a history request
        // with a two-byte payload that is not a record packet. Failing the
        // request left the consumer without a terminator, so it must be read as
        // "nothing left" instead.
        let (session, transport) = try makeSession { frame in
            guard frame.cmd == SibionicsCommand.historyRequest else { return [] }
            return [
                SibionicsFrame(cmd: SibionicsCommand.historyRecord, payload: Data([0x02, 0x00]))
            ]
        }
        try await session.start()
        await transport.waitForSubscriber()

        let packet = try await session.requestHistory(from: 901, to: 904)
        XCTAssertTrue(packet.isEmptyHistoryTerminator, "an odd payload must terminate, not throw")
        session.close()
    }

    func testRequestAfterCloseFails() async throws {
        let (session, transport) = try makeSession { _ in [] }
        try await session.start()
        await transport.waitForSubscriber()
        session.close()
        do {
            _ = try await session.deviceTime()
            XCTFail("expected the request to be refused")
        } catch let error as SibionicsSession.SessionError {
            XCTAssertEqual(error.description, SibionicsSession.SessionError.closed.description)
        }
    }
}

extension FakeSensorTransport {
    func pushRaw(_ sealed: Data) {
        queue.async { self.continuation?.yield(sealed) }
    }
}
