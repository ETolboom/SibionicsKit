import Foundation

/// Turns a live session into dated readings.
///
/// The monitor owns exactly one thing the rest of the stack must not duplicate:
/// mapping a record's minute index onto a wall-clock date using the sensor's own
/// activation stamp. Everything downstream (warmup, forwarding grid, backfill)
/// is expressed in record indices so it survives the phone's clock moving.
public final class SibionicsSensorMonitor: @unchecked Sendable {
    public struct Reading: Equatable, Sendable {
        public let record: SibionicsRecord
        public let date: Date
        public let receivedAt: Date
        public let elapsedSeconds: TimeInterval
        public let isHistorical: Bool
        public let trend: GlucoseSample.Trend
        public let rateOfChangeMgDLPerMinute: Double?
    }

    public typealias ReadingHandler = @Sendable(Reading) -> Void
    public typealias DisconnectHandler = @Sendable() -> Void
    public typealias StatusHandler = @Sendable(String) -> Void
    /// Called for every record the sensor sends, including the ones with no
    /// result. Those carry no value but they do prove the index exists, which is
    /// what stops the gap detector asking for it again.
    public typealias RecordSeenHandler = @Sendable(UInt16, Bool) -> Void
    public typealias BackfillCompleteHandler = @Sendable() -> Void
    /// Fired once, when the sensor's start time becomes known — from its clock,
    /// or learned from the first record when the clock is unavailable. Lets the
    /// manager persist it so a moved sensor shows a real age instead of "no
    /// sensor".
    public typealias ActivationHandler = @Sendable(Date) -> Void

    public let session: SibionicsSession
    public private(set) var activatedAt: Date?

    private let warmup: TimeInterval
    private let logger = SibionicsLogger(category: "Monitor")
    private let lock = NSLock()

    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var historyWatchdog: Task<Void, Never>?

    private var readingHandler: ReadingHandler?
    private var recordSeenHandler: RecordSeenHandler?
    private var disconnectHandler: DisconnectHandler?
    private var statusHandler: StatusHandler?
    private var backfillCompleteHandler: BackfillCompleteHandler?
    private var activationHandler: ActivationHandler?
    private var reportedActivation = false

    /// Shared by live and backfilled readings: both sit on the same index
    /// line, so a backfilled reading is a valid neighbour for a live one.
    private var trendTracker = SibionicsTrendTracker(maxGapMinutes: 6)

    /// A record index is one minute, starting at activation. If the sensor turns
    /// out to emit index 0 a minute late (as the sibling kits do), that is a
    /// constant offset in `date`, not a reason to change the mapping here.
    public static let secondsPerRecord: TimeInterval = 60

    private static let staleTimeout: TimeInterval = 6 * 60
    private static let historyStallTimeout: TimeInterval = 25

    public init(session: SibionicsSession, warmup: TimeInterval, activatedAt: Date? = nil) {
        self.session = session
        self.warmup = warmup
        self.activatedAt = activatedAt
    }

    public func setHandlers(
        onReading: @escaping ReadingHandler,
        onDisconnect: @escaping DisconnectHandler,
        onStatus: @escaping StatusHandler = { _ in },
        onBackfillComplete: @escaping BackfillCompleteHandler = {},
        onRecordSeen: @escaping RecordSeenHandler = { _, _ in },
        onActivationLearned: @escaping ActivationHandler = { _ in }
    ) {
        lock.withLock {
            readingHandler = onReading
            disconnectHandler = onDisconnect
            statusHandler = onStatus
            backfillCompleteHandler = onBackfillComplete
            activationHandler = onActivationLearned
            recordSeenHandler = onRecordSeen
        }
    }

    /// Sets the start time and tells the manager once, so an activation time
    /// discovered during this session is persisted.
    private func establishActivation(_ date: Date) {
        let handler = lock.withLock { () -> ActivationHandler? in
            activatedAt = date
            guard !reportedActivation else { return nil }
            reportedActivation = true
            return activationHandler
        }
        handler?(date)
    }

    // MARK: - Lifecycle

    /// Establishes the sensor's clock, then streams records. Run once per
    /// connection.
    public func run(historyFrom lastKnownIndex: UInt16?) async {
        // Already started by the pairing service; idempotent.
        do {
            try await session.start()
        } catch {
            logger.error("could not subscribe to the sensor: \(error.localizedDescription)")
            emitStatus(error.localizedDescription)
            return
        }
        emitStatus(LocalizedString("Connecting to sensor…", comment: "Status: connecting"))

        // The activation stamp normally comes from the activation ack and is
        // persisted, so this is a correction rather than a dependency: the
        // official app never asks the sensor for its clock (`0xF0 0x03`), so a
        // firmware that doesn't answer must not stop the session.
        do {
            guard lock.withLock({ activatedAt == nil }) else { throw CancellationError() }
            let time = try await session.deviceTime()
            if let reported = time.activationDate {
                let known = lock.withLock { activatedAt }
                if let known, abs(known.timeIntervalSince(reported)) > 2 {
                    logger.warning("sensor clock says \(reported), stored activation \(known); using the sensor")
                }
                establishActivation(reported)
                logger.info("sensor clock: activation=\(reported) lastIndex=\(time.lastIndex)")
            } else {
                logger.warning("sensor clock reports no activation stamp")
            }
        } catch is CancellationError {
            logger.debug("start time already known; skipping the clock probe")
        } catch {
            logger.debug("sensor clock unavailable (\(error.localizedDescription)); using the stored activation time")
        }
        if lock.withLock({ activatedAt == nil }) {
            logger.warning("no activation time known yet; dating the first record by its arrival")
        }

        armWatchdog()
        let readingTask = Task { [weak self] in
            guard let self else { return }
            for await record in self.session.records() {
                if Task.isCancelled { break }
                self.handle(record, isHistorical: false)
            }
            self.lock.withLock { self.disconnectHandler }?()
        }
        lock.withLock { task = readingTask }

        // Live records decide history: the first live record after a reconnect
        // tells us the newest index, so request anything before it that we know
        // we are missing.
        if let lastKnownIndex {
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.requestHistory(from: lastKnownIndex &+ 1)
                } catch {
                    self.logger.debug("history request failed: \(error.localizedDescription)")
                }
            }
        }
    }

    public func stop() {
        let tasks = lock.withLock { () -> (Task<Void, Never>?, Task<Void, Never>?, Task<Void, Never>?) in
            let tuple = (task, watchdog, historyWatchdog)
            task = nil
            watchdog = nil
            historyWatchdog = nil
            return tuple
        }
        tasks.0?.cancel()
        tasks.1?.cancel()
        tasks.2?.cancel()
    }

    public func disconnect() {
        stop()
        session.close()
    }

    // MARK: - History

    /// Requests history from `index` onward and pumps it until the batch ends.
    /// The session ends the batch on the sensor's empty terminator, or after a
    /// period of silence, so this always returns.
    /// Fetches `index…last`, **re-requesting** while the sensor keeps answering
    /// with less than the whole range.
    ///
    /// A GS3 answers a history request with one batch and then terminates it, so
    /// a single request only ever covers the first chunk — which is why backfill
    /// used to stop after roughly an hour. The sensor does not say how much it
    /// is willing to send, so the loop is driven by what actually arrived: keep
    /// asking from just past the highest index delivered until the range is
    /// covered or a request stops making progress.
    /// `last` bounds what is *delivered*; the sensor is always asked for
    /// everything to the end, because that is the only form it serves (a bounded
    /// `last` comes back as a two-byte `01 00` instead of records).
    public func requestHistory(from index: UInt16, to last: UInt16 = .max) async throws {
        emitStatus(LocalizedString("Catching up…", comment: "Status: backfill"))
        var next = index
        var requests = 0
        var delivered = 0

        while next <= last, requests < Self.maxHistoryRequests {
            requests += 1
            let first = try await session.requestHistory(from: next)
            if first.isEmptyHistoryTerminator {
                logger.debug("history finished after \(requests) request(s), \(delivered) record(s)")
                break
            }

            var highest = first.records.last?.index ?? first.startIndex
            let firstCount = first.records.count
            deliver(first, isHistorical: true, upTo: last)
            delivered += firstCount

            // Anything the sensor keeps pushing for this request.
            var ended = false
            for await event in session.historyEvents() {
                switch event {
                case let .packet(packet):
                    deliver(packet, isHistorical: true, upTo: last)
                    delivered += packet.records.count
                    if let lastRecord = packet.records.last { highest = max(highest, lastRecord.index) }
                case .batchEnd:
                    ended = true
                }
                if ended { break }
            }

            // No progress means asking again would repeat the same chunk.
            guard highest >= next, highest < UInt16.max else {
                logger.debug("history stopped making progress at \(highest)")
                break
            }
            next = highest &+ 1
            // The stream ended without a terminator, i.e. the link went away.
            if !ended { break }
        }

        logger.debug(
            "history complete: \(delivered) record(s) over \(requests) request(s), up to \(min(next, last))"
        )
        lock.withLock { backfillCompleteHandler }?()
    }

    /// Each request is one gap chunk; a 14-day sensor at one record a minute is
    /// ~20k records, so this is a runaway guard, not a real limit.
    private static let maxHistoryRequests = 256

    private func deliver(_ packet: SibionicsGlucosePacket, isHistorical: Bool, upTo bound: UInt16 = .max) {
        for record in packet.records where record.index <= bound {
            handle(record, isHistorical: isHistorical)
        }
    }

    /// Forces a real disconnect if the link stays up but the sensor goes quiet.
    private func armWatchdog() {
        watchdog?.cancel()
        let watchdog = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: UInt64(Self.staleTimeout * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.logger.debug("no records for \(Int(Self.staleTimeout))s; forcing a reconnect")
                self.session.close()
                return
            }
        }
        lock.withLock { self.watchdog = watchdog }
    }

    // MARK: - Decode

    private func handle(_ record: SibionicsRecord, isHistorical: Bool) {
        // Every record counts as seen, value or not: the 0xFF01 ones index real
        // minutes, and without this the gap detector re-requests them forever
        // and the sensor answers `01 00` because there is nothing to send.
        lock.withLock { recordSeenHandler }?(record.index, isHistorical)
        // The link is demonstrably alive, so the stale timer restarts here. It
        // used to be armed once per connection and never reset, which killed a
        // perfectly healthy link every six minutes and looked exactly like the
        // sensor hanging up.
        armWatchdog()
        // A record flagged present_cstate is the sensor saying "do not use this
        // one". Drop it rather than forward a value the firmware already
        // disowned.
        guard !record.presentCState else {
            logger.debug("dropping flagged record seq=\(record.index)")
            return
        }
        guard let mgDL = record.glucoseMgDL else {
            logger.debug("no result in record seq=\(record.index) (0x\(String(record.displayGlucoseRaw, radix: 16)))")
            return
        }
        emit(record, mgDL: mgDL, isHistorical: isHistorical)
    }

    private func emit(_ record: SibionicsRecord, mgDL: Double, isHistorical: Bool) {
        let receivedAt = Date()
        let elapsed = Self.secondsPerRecord * Double(record.index)
        // Last resort: anchor on the first record's arrival. Off by however long
        // the record took to reach us, so it is only used when the sensor gave no
        // clock, and it is persisted like a real one.
        let known = lock.withLock { activatedAt }
        let base = known ?? receivedAt.addingTimeInterval(-elapsed)
        if known == nil { establishActivation(base) }
        let date = base.addingTimeInterval(elapsed)

        let (trend, rate) = deriveTrend(
            sequence: record.index, mgDL: mgDL, elapsed: elapsed
        )

        let reading = Reading(
            record: record, date: date, receivedAt: receivedAt, elapsedSeconds: elapsed,
            isHistorical: isHistorical, trend: trend, rateOfChangeMgDLPerMinute: rate
        )
        logger.debug(
            "[\(isHistorical ? "bf" : "rt")] \(record.description) date=\(date) trend=\(trend)"
        )
        lock.withLock { readingHandler }?(reading)
    }

    private func deriveTrend(
        sequence: UInt16, mgDL: Double, elapsed: TimeInterval
    ) -> (GlucoseSample.Trend, Double?) {
        lock.withLock { trendTracker.trend(sequence: sequence, mgDL: mgDL, elapsed: elapsed) }
    }

    private func emitStatus(_ text: String) {
        lock.withLock { statusHandler }?(text)
    }
}
