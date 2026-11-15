import Foundation

/// One authenticated conversation with a sensor.
///
/// The protocol is strictly request/response on a single notify characteristic,
/// with unsolicited `0x32` pushes arriving once a minute. This type owns the
/// pending-reply bookkeeping, the decryption, and the demultiplexing of replies
/// versus records, so callers see plain `async` calls and two streams.
public final class SibionicsSession: @unchecked Sendable {
    public enum SessionError: Error, LocalizedError, CustomStringConvertible {
        case closed
        case timeout(cmd: UInt8)
        case rejectBoot
        case rejected(String)
        case unauthenticated
        /// Decryption produced something that is not a valid frame. Almost
        /// always a wrong MAC (hence wrong IV), or a sensor whose transport key
        /// differs from `SibionicsCipher.transportKey`.
        case undecryptable
        case malformed(String)
        case notSupported(String)
        /// `start()` was never called, so nothing is listening on `ff31` and the
        /// sensor's reply would be dropped. Reported instead of silently timing
        /// out, because that is exactly how it looked once already.
        case notSubscribed
        /// The sensor answered, and the answer was "no". For auth this means the
        /// account id does not match the one this sensor is bound to (or the
        /// sensor refused the registration key).
        case authenticationRejected(status: UInt8?)

        public var description: String {
            switch self {
            case .closed: return "the sensor connection is closed"
            case let .timeout(cmd): return String(format: "the sensor did not answer 0x%02x in time", cmd)
            case .rejectBoot: return "the sensor rejected the request"
            case let .rejected(reason): return "the sensor rejected the request: \(reason)"
            case .unauthenticated: return "the sensor is not authenticated (it answered with its bootstrap frame)"
            case .undecryptable:
                return "could not decrypt the sensor's reply — check that the MAC is correct for this sensor"
            case let .malformed(detail): return "malformed sensor reply: \(detail)"
            case let .notSupported(detail): return "unsupported: \(detail)"
            case .notSubscribed:
                return "internal: the session was not started before sending (no reply could arrive)"
            case let .authenticationRejected(status):
                let code = status.map { String(format: "0x%02x", $0) } ?? "none"
                return "the sensor refused this account id (status \(code)) — it was activated with a different one"
            }
        }

        public var errorDescription: String? { description }
    }

    public enum HistoryEvent: Equatable, Sendable {
        case packet(SibionicsGlucosePacket)
        /// The sensor answered with an empty `0x39`, i.e. "nothing more".
        case batchEnd
    }

    public let peripheralID: UUID
    /// Upper-case, separators stripped. Redact before logging.
    public let mac: String
    public let firmware: SibionicsProtocolVersion

    private let transport: SibionicsGATTTransport
    private let cipher: SibionicsCipher
    private let logger = SibionicsLogger(category: "Session")

    private let lock = NSLock()
    private var pendingReplies: [UInt8: PendingReply] = [:]
    private var pendingHistory: PendingHistory?
    private var receiveTask: Task<Void, Never>?
    private var historyContinuation: AsyncStream<HistoryEvent>.Continuation?
    private var historyIdleTask: Task<Void, Never>?
    private var recordContinuation: AsyncStream<SibionicsRecord>.Continuation?
    /// Records and history packets that arrived before anyone subscribed. A
    /// batch is delivered in one burst, so a consumer that attaches *after*
    /// `requestHistory` returns would otherwise miss everything but the
    /// terminator.
    private var recordBacklog: [SibionicsRecord] = []
    private var historyBacklog: [HistoryEvent] = []
    private static let backlogLimit = 512
    private var closed = false
    private(set) var sawUnauthenticatedBootstrap = false
    /// True once `start()` has confirmed the notification subscription.
    private var subscribed = false

    /// How long to wait for a reply. Tests shorten this; production does not
    /// need to.
    var requestTimeout: TimeInterval = 10
    /// Timeout for a history request, which the sensor answers with a batch.
    var historyTimeout: TimeInterval = 20
    /// A batch is considered over when the sensor goes quiet this long, so a
    /// firmware that stops mid-batch cannot strand the consumer.
    var historyIdleTimeout: TimeInterval = 20

    private final class PendingReply {
        let continuation: CheckedContinuation<SibionicsReply, Error>
        var done = false
        init(_ continuation: CheckedContinuation<SibionicsReply, Error>) {
            self.continuation = continuation
        }
    }

    private final class PendingHistory {
        let continuation: CheckedContinuation<SibionicsGlucosePacket, Error>
        var done = false
        init(_ continuation: CheckedContinuation<SibionicsGlucosePacket, Error>) {
            self.continuation = continuation
        }
    }

    public init(transport: SibionicsGATTTransport, mac: String, firmware: SibionicsProtocolVersion) throws {
        self.transport = transport
        self.mac = Self.normalise(mac)
        self.firmware = firmware
        cipher = try SibionicsCipher(mac: mac)
        peripheralID = transport.peripheralID
    }

    static func normalise(_ mac: String) -> String { mac.uppercased().filter(\.isHexDigit) }

    // MARK: - Streams

    /// Every measurement record the sensor pushes: live `0x32`, cached `0x36`,
    /// and the records inside `0x39` history packets.
    public func records() -> AsyncStream<SibionicsRecord> {
        AsyncStream { continuation in
            // Replay inside the lock: yielding after releasing it would let a
            // live record overtake the backlog and reorder the stream.
            lock.withLock {
                let backlog = recordBacklog
                recordBacklog = []
                for record in backlog { continuation.yield(record) }
                recordContinuation = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.recordContinuation = nil }
            }
        }
    }

    /// History packets after the first one of each request (that one comes back
    /// from `requestHistory`). Ends with `.batchEnd`.
    public func historyEvents() -> AsyncStream<HistoryEvent> {
        AsyncStream { continuation in
            // Same reasoning as `records()`, and it matters more here: a live
            // `.batchEnd` that overtook the replay would finish the stream and
            // silently discard the earlier packets.
            let alreadyFinished = lock.withLock { () -> Bool in
                let backlog = historyBacklog
                historyBacklog = []
                for event in backlog { continuation.yield(event) }
                if backlog.contains(.batchEnd) {
                    historyContinuation = nil
                    return true
                }
                historyContinuation = continuation
                return false
            }
            if alreadyFinished { continuation.finish() }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.historyContinuation = nil }
            }
        }
    }

    // MARK: - Lifecycle

    /// Subscribes to `ff31` and starts consuming it. Returns only once the
    /// peripheral has acknowledged the subscription, so the next thing a caller
    /// does — usually the auth write — cannot beat the notification enable and
    /// lose the reply.
    public func start() async throws {
        let alreadyRunning = lock.withLock { receiveTask != nil }
        guard !alreadyRunning else { return }

        let stream: AsyncStream<Data>
        do {
            stream = try await transport.subscribe(SibionicsGATT.notifyCharacteristic)
        } catch {
            logger.error("could not subscribe to notifications: \(error.localizedDescription)")
            throw SessionError.notSubscribed
        }
        lock.withLock { subscribed = true }
        let task = Task { [weak self] in
            guard let self else { return }
            for await notify in stream {
                if Task.isCancelled { break }
                self.receive(notify)
            }
            self.handleLinkClosed()
        }
        lock.withLock { receiveTask = task }
        logger.debug("subscribed to notifications")
    }

    public func close() {
        let state = lock
            .withLock { () -> (
                Task<Void, Never>?,
                AsyncStream<SibionicsRecord>.Continuation?,
                AsyncStream<HistoryEvent>.Continuation?
            ) in
                closed = true
                let state = (receiveTask, recordContinuation, historyContinuation)
                receiveTask = nil
                recordContinuation = nil
                historyContinuation = nil
                return state
            }
        failAllPending(SessionError.closed)
        state.0?.cancel()
        state.1?.finish()
        state.2?.finish()
        historyIdleTask?.cancel()
        transport.disconnect()
    }

    private func handleLinkClosed() {
        let state = lock.withLock {
            closed = true
            subscribed = false
            let state = (recordContinuation, historyContinuation)
            recordContinuation = nil
            historyContinuation = nil
            return state
        }
        failAllPending(SessionError.closed)
        state.0?.finish()
        state.1?.finish()
        logger.debug("session link closed")
    }

    private func failAllPending(_ error: Error) {
        let (replies, history) = lock.withLock { () -> ([PendingReply], PendingHistory?) in
            let replies = pendingReplies.values.filter { !$0.done }
            for entry in replies { entry.done = true }
            pendingReplies.removeAll()
            let history = pendingHistory
            pendingHistory = nil
            return (replies, history)
        }
        replies.forEach { $0.continuation.resume(throwing: error) }
        if let history, !history.done {
            history.done = true
            history.continuation.resume(throwing: error)
        }
    }

    // MARK: - Requests

    /// V3 auth. A wrong account id is reported from this call, because the
    /// sensor checks the account id inside the auth frame.
    @discardableResult public func authenticate(
        registrationKey: Data,
        accountID: SibionicsAccountID
    ) async throws -> SibionicsReply {
        let frame = try SibionicsCommand.authFrame(mac: mac, registrationKey: registrationKey, accountID: accountID)
        let reply = try await send(frame, expecting: SibionicsCommand.auth)
        let status = reply.status
        // `E2 01 00` is the documented success ack, so anything else is a
        // refusal. Being strict here matters: the next thing the driver would
        // otherwise do is write an activation command to a sensor that never
        // authorised us.
        if let status, status != 0x01 {
            logger.warning("auth refused (status \(String(format: "0x%02x", status)))")
            throw SessionError.authenticationRejected(status: status)
        }
        logger.info("authenticated (status \(status.map { String(format: "0x%02x", $0) } ?? "none"))")
        return reply
    }

    /// What the sensor answered to an activation.
    ///
    /// Verified against a hardware capture: `09 35 01 00 <time LE> <cksum>` —
    /// status `0x01`, then the activation time echoed back. That echo is the
    /// confirmation, and it is what the official app relies on: it never asks
    /// for the device clock (`0xF0 0x03`) at all.
    public struct ActivationAck: Equatable, Sendable {
        public let status: UInt8
        /// Unix seconds the sensor says it started at.
        public let timestamp: UInt32

        public var isSuccess: Bool { status == 0x01 }
        public var activationDate: Date { Date(timeIntervalSince1970: TimeInterval(timestamp)) }

        /// Payload layout: `status u8 ‖ 0x00 ‖ timestamp u32 LE`.
        public static func parse(_ payload: Data) -> ActivationAck? {
            let bytes = [UInt8](payload)
            guard bytes.count >= 6 else { return nil }
            let seconds = UInt32(bytes[2]) | (UInt32(bytes[3]) << 8)
                | (UInt32(bytes[4]) << 16) | (UInt32(bytes[5]) << 24)
            return ActivationAck(status: bytes[0], timestamp: seconds)
        }
    }

    /// V3 activation. `activationTime` becomes the sensor's clock origin, and
    /// `ts` is unix seconds.
    ///
    /// Throws unless the sensor answers with status `0x01` *and* echoes the
    /// timestamp we sent, so a rejected or ignored activation is never mistaken
    /// for a successful one.
    @discardableResult public func activateBindIn(
        activationTime: Date,
        accountID: SibionicsAccountID
    ) async throws -> ActivationAck {
        let seconds = UInt32(clamping: Int(activationTime.timeIntervalSince1970))
        let frame = try SibionicsCommand.activateBindInFrame(activationTime: seconds, accountID: accountID)
        logger.info("sending activation 0x35 with timestamp \(seconds)")
        let reply = try await send(frame, expecting: SibionicsCommand.activateBindIn)
        guard let ack = ActivationAck.parse(reply.payload) else {
            throw SessionError.malformed("activation ack payload is \(reply.payload.count) bytes")
        }
        guard ack.isSuccess else {
            throw SessionError.rejected(String(format: "activation ack status 0x%02x", ack.status))
        }
        guard ack.timestamp == seconds else {
            throw SessionError.rejected("activation ack echoed \(ack.timestamp), sent \(seconds)")
        }
        logger.info("activation ack confirmed, sensor started \(ack.activationDate)")
        return ack
    }

    // MARK: - Info queries

    public struct DeviceTime: Equatable, Sendable {
        public let startover: UInt16
        /// Unix seconds, or 0 when the sensor is not activated.
        public let activation: UInt32
        public let current: UInt32
        public let last: UInt32
        public let lastIndex: UInt16

        public var isActivated: Bool { activation > 0 }
        public var activationDate: Date? {
            isActivated ? Date(timeIntervalSince1970: TimeInterval(activation)) : nil
        }

        public var elapsedSeconds: TimeInterval? {
            guard isActivated, current >= activation else { return nil }
            return TimeInterval(current - activation)
        }
    }

    /// `0xF0 0x03`: the sensor's own clock. Authoritative for "is this sensor
    /// activated, and when did it start".
    /// `timeout` is short by default: the official app never asks for the clock,
    /// so a firmware may simply ignore `0xF0 0x03`, and a caller probing
    /// speculatively should not wait out the full request timeout.
    public func deviceTime(timeout: TimeInterval = 3) async throws -> DeviceTime {
        let reply = try await send(
            SibionicsCommand.infoQueryFrame(SibionicsCommand.infoDeviceTime),
            expecting: SibionicsCommand.infoQuery,
            timeout: timeout
        )
        return try Self.parseDeviceTime(reply.payload)
    }

    /// `startover u16 | activation u32 | current u32 | last u32 | lastIndex u16`, all LE.
    public static func parseDeviceTime(_ payload: Data) throws -> DeviceTime {
        var bytes = [UInt8](payload)
        // A reply echoes its sub-opcode first; callers may or may not strip it.
        if bytes.first == SibionicsCommand.infoDeviceTime { bytes.removeFirst() }
        guard bytes.count >= 14 else {
            throw SessionError.malformed("device time payload is \(bytes.count) bytes, expected 14")
        }
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8) }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
        }
        return DeviceTime(
            startover: u16(0),
            activation: u32(2),
            current: u32(6),
            last: u32(10),
            lastIndex: u16(14)
        )
    }

    /// `0xF0 0x0E`: the product serial, e.g. `04ES126090500NA`. That is the same
    /// string an applicator tag carries, so it is how a tag read is checked
    /// against the sensor actually attached.
    ///
    /// Reply layout from the capture: `0e 01 ‖ ascii ‖ zeros`.
    public func deviceSerial(timeout: TimeInterval = 5) async throws -> String? {
        let reply = try await send(
            SibionicsCommand.infoQueryFrame(SibionicsCommand.infoExtended),
            expecting: SibionicsCommand.infoQuery,
            timeout: timeout
        )
        let bytes = [UInt8](reply.payload)
        guard bytes.count > 2 else { return nil }
        let run = bytes.dropFirst(2).drop { $0 < 0x20 }.prefix { $0 >= 0x20 && $0 < 0x7F }
        guard run.count >= 4, let text = String(bytes: run, encoding: .utf8) else { return nil }
        return text
    }

    /// Any other info sub-query, returned raw. Nothing in the driver depends on
    /// these beyond logging.
    public func infoQuery(_ sub: UInt8) async throws -> SibionicsReply {
        try await send(SibionicsCommand.infoQueryFrame(sub), expecting: SibionicsCommand.infoQuery)
    }

    // MARK: - History

    /// Sends a history request and returns the first reply packet. Further
    /// packets arrive on `historyEvents()`.
    @discardableResult public func requestHistory(
        from first: UInt16,
        to last: UInt16 = 0
    ) async throws -> SibionicsGlucosePacket {
        guard !lock.withLock({ closed }) else { throw SessionError.closed }
        guard lock.withLock({ subscribed }) else { throw SessionError.notSubscribed }
        let sealed = try cipher.seal(SibionicsCommand.historyRequestFrame(from: first, to: last))

        return try await withCheckedThrowingContinuation { continuation in
            let waiter = PendingHistory(continuation)
            let superseded = lock.withLock { () -> PendingHistory? in
                let previous = pendingHistory
                pendingHistory = waiter
                return previous
            }
            if let superseded, !superseded.done {
                superseded.done = true
                superseded.continuation.resume(throwing: SessionError.malformed("superseded by a newer request"))
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transport.write(sealed, to: SibionicsGATT.writeCharacteristic, withResponse: true)
                } catch {
                    self.resolveHistory(waiter, .failure(error))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((self?.historyTimeout ?? 20) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.resolveHistory(waiter, .failure(SessionError.timeout(cmd: SibionicsCommand.historyRecord)))
            }
        }
    }

    private func resolveHistory(_ waiter: PendingHistory, _ result: Result<SibionicsGlucosePacket, Error>) {
        let shouldResume = lock.withLock { () -> Bool in
            guard !waiter.done else { return false }
            waiter.done = true
            if pendingHistory === waiter { pendingHistory = nil }
            return true
        }
        guard shouldResume else { return }
        switch result {
        case let .success(packet): waiter.continuation.resume(returning: packet)
        case let .failure(error): waiter.continuation.resume(throwing: error)
        }
    }

    // MARK: - Receive path

    private func receive(_ notify: Data) {
        let plaintext: Data
        do {
            plaintext = try cipher.open(notify)
        } catch {
            logger.error("decrypt failed: \(error.localizedDescription)")
            return
        }

        guard let reply = SibionicsReply(decoding: plaintext) else {
            logger.error("undecryptable notify (\(notify.count) B) — wrong MAC for this sensor?")
            failAllPending(SessionError.undecryptable)
            return
        }

        if reply.isUnauthenticatedBootstrap {
            logger.warning("sensor answered with its unauthenticated bootstrap frame")
            lock.withLock { sawUnauthenticatedBootstrap = true }
            failAllPending(SessionError.unauthenticated)
            return
        }

        if SibionicsDiagnostics.verboseBLELogging {
            logger.debug("rx \(reply.description)")
        }

        switch reply.cmd {
        case SibionicsCommand.cachedRecord,
             SibionicsCommand.liveRecord:
            if let packet = SibionicsGlucosePacket(cmd: reply.cmd, payload: reply.payload) {
                forwardRecords(packet)
            }
            resolveReply(reply)

        case SibionicsCommand.historyRecord:
            guard let packet = SibionicsGlucosePacket(cmd: reply.cmd, payload: reply.payload) else {
                // A two-byte payload is the ACK form, not a truncated packet:
                // `04 39 <status> <detail> <cksum>`. Status 0 means the sensor
                // had nothing to send; anything else means it refused the
                // request, which is worth saying out loud rather than logging
                // as an unreadable packet.
                if reply.isAck {
                    let status = reply.ackStatus ?? 0
                    if status == 0 {
                        logger.debug("history: sensor has nothing to send (ack 0)")
                    } else {
                        logger.warning(
                            "history request refused: ack status \(status)"
                                + " detail \(reply.ackDetail.map(String.init) ?? "-")"
                        )
                    }
                } else {
                    logger.warning(
                        "history reply payload of \(reply.payload.count) B is not a record packet"
                            + " (\(Self.hex(reply.payload))) — treating it as the end of the batch"
                    )
                }
                deliverHistory(.emptyHistoryTerminator)
                return
            }
            deliverHistory(packet)

        default:
            resolveReply(reply)
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    private func forwardRecords(_ packet: SibionicsGlucosePacket) {
        let continuation = lock.withLock { recordContinuation }
        if let continuation {
            for record in packet.records { continuation.yield(record) }
            return
        }
        lock.withLock {
            recordBacklog.append(contentsOf: packet.records)
            if recordBacklog.count > Self.backlogLimit {
                recordBacklog.removeFirst(recordBacklog.count - Self.backlogLimit)
            }
        }
    }

    /// Queues a history event when nobody is listening yet.
    private func bufferHistory(_ event: HistoryEvent) {
        lock.withLock {
            historyBacklog.append(event)
            if historyBacklog.count > Self.backlogLimit {
                historyBacklog.removeFirst(historyBacklog.count - Self.backlogLimit)
            }
        }
    }

    private func deliverHistory(_ packet: SibionicsGlucosePacket) {
        // Arm the stall timer on every packet, including the first: a batch that
        // stops after one packet must still terminate for the consumer.
        if !packet.isEmptyHistoryTerminator { armHistoryIdle() }
        // The first packet of a batch is returned by `requestHistory`; feeding
        // it to the stream too would duplicate every record in it.
        let waiter = lock.withLock { () -> PendingHistory? in
            let waiter = pendingHistory
            pendingHistory = nil
            return waiter
        }
        let isFirst = waiter != nil
        if let waiter, !waiter.done {
            waiter.done = true
            waiter.continuation.resume(returning: packet)
        } else {
            let continuation = lock.withLock { historyContinuation }
            if let continuation {
                if packet.isEmptyHistoryTerminator {
                    historyIdleTask?.cancel()
                    continuation.yield(.batchEnd)
                    continuation.finish()
                    lock.withLock { self.historyContinuation = nil }
                } else {
                    continuation.yield(.packet(packet))
                }
            } else {
                // Nobody is subscribed yet; keep the burst for whoever comes next.
                bufferHistory(packet.isEmptyHistoryTerminator ? .batchEnd : .packet(packet))
            }
        }
        if !isFirst {
            forwardRecords(packet)
        }
    }

    /// Ends the batch after a period of silence. A real terminator is preferred;
    /// this only exists so a stalled batch cannot leave the caller looping
    /// forever on a stream that will never produce another element.
    private func armHistoryIdle() {
        let timeout = historyIdleTimeout
        historyIdleTask?.cancel()
        historyIdleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let continuation = self.lock.withLock { () -> AsyncStream<HistoryEvent>.Continuation? in
                let existing = self.historyContinuation
                self.historyContinuation = nil
                return existing
            }
            guard let continuation else {
                self.bufferHistory(.batchEnd)
                return
            }
            self.logger.debug("history went quiet; ending the batch")
            continuation.yield(.batchEnd)
            continuation.finish()
        }
    }

    private func resolveReply(_ reply: SibionicsReply) {
        let waiter = lock.withLock { () -> PendingReply? in
            guard let entry = pendingReplies[reply.cmd], !entry.done else { return nil }
            entry.done = true
            pendingReplies.removeValue(forKey: reply.cmd)
            return entry
        }
        waiter?.continuation.resume(returning: reply)
    }

    // MARK: - Send

    private func send(
        _ frame: SibionicsFrame,
        expecting cmd: UInt8,
        timeout: TimeInterval? = nil
    ) async throws -> SibionicsReply {
        guard !lock.withLock({ closed }) else { throw SessionError.closed }
        guard lock.withLock({ subscribed }) else { throw SessionError.notSubscribed }
        let sealed = try cipher.seal(frame)
        return try await withCheckedThrowingContinuation { continuation in
            let entry = PendingReply(continuation)
            let previous = lock.withLock { () -> PendingReply? in
                let previous = pendingReplies[cmd]
                pendingReplies[cmd] = entry
                return previous
            }
            if let previous, !previous.done {
                previous.done = true
                previous.continuation.resume(throwing: SessionError.malformed("superseded"))
            }

            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.transport.write(sealed, to: SibionicsGATT.writeCharacteristic, withResponse: true)
                } catch {
                    self.resolve(entry, for: cmd, .failure(error))
                }
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((timeout ?? self?.requestTimeout ?? 10) * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.resolve(entry, for: cmd, .failure(SessionError.timeout(cmd: cmd)))
            }
        }
    }

    private func resolve(_ entry: PendingReply, for cmd: UInt8, _ result: Result<SibionicsReply, Error>) {
        let shouldResume = lock.withLock { () -> Bool in
            guard !entry.done else { return false }
            entry.done = true
            if pendingReplies[cmd] === entry { pendingReplies.removeValue(forKey: cmd) }
            return true
        }
        guard shouldResume else { return }
        switch result {
        case let .success(reply): entry.continuation.resume(returning: reply)
        case let .failure(error): entry.continuation.resume(throwing: error)
        }
    }
}
