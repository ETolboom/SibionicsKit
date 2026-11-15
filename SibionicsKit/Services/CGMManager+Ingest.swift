import Foundation
@preconcurrency import LoopKit

extension SibionicsCGMManager {
    /// One forwarded reading per this many records (1 record = 1 minute).
    static let forwardGridStep: UInt16 = 5
    static func isOnForwardGrid(sequence: UInt16) -> Bool { sequence % forwardGridStep == 0 }

    @MainActor func ingest(_ reading: SibionicsSensorMonitor.Reading) {
        if state.sensorNeedsReplacement {
            logger.debug("sensor marked for replacement; dropping seq=\(reading.record.index)")
            return
        }

        guard let value = reading.record.glucoseMgDL else { return }
        let sequence = reading.record.index

        var sample = GlucoseSample(
            date: reading.date,
            valueMgDL: value,
            trend: reading.trend,
            rateOfChangeMgDLPerMinute: reading.rateOfChangeMgDLPerMinute,
            sequence: sequence,
            rawDisplayMgDL: value,
            rawCurrent: Double(reading.record.currentRaw),
            elapsedSeconds: reading.elapsedSeconds,
            hasBlockingIssue: false,
            source: reading.isHistorical ? .historicalBackfill : .realtime
        )

        let isWarmup = Self.isWarmup(elapsedSeconds: sample.elapsedSeconds, warmup: state.warmup)
        let isExpired = Self.isPastWear(elapsedSeconds: sample.elapsedSeconds, activeDuration: state.activeDuration)
        if !isWarmup, !isExpired { recordSample(sample) }

        // A live record that is newer than our watermark means a gap: ask for
        // whatever lies between. Doing it from the live stream (rather than from
        // the disconnect) catches frames lost without a disconnect.
        if sample.source == .realtime {
            requestGapBefore(sequence: sequence, on: monitor)
        }

        var updated = state
        if sample.source == .realtime,
           sequence >= (updated.lastIngestedSequence ?? 0)
        {
            updated.latestReadingTimestamp = reading.receivedAt
            updated.lastIngestedSequence = sequence
        }
        setState(updated)

        guard !isWarmup else {
            logger.debug("warmup: \(Int(value)) mg/dL seq=\(sequence); not forwarding")
            return
        }
        guard !isExpired else {
            logger.debug("past wear: \(Int(value)) mg/dL seq=\(sequence); not forwarding")
            return
        }

        // Electrode-current plausibility. Fed post-warmup live samples only: a
        // backfilled streak is historical and must not retro-latch the sensor.
        if sample.source == .realtime, let current = sample.rawCurrent {
            if let event = plausibilityGuard.record(sequence: sequence, current: current) {
                switch event.level {
                case .attention:
                    logger.warning("implausible streak at seq=\(sequence); suppressing forwarding while it holds")
                case .broken:
                    logger.error("implausible streak at seq=\(sequence); declaring the sensor failed")
                    markSensorFailed(SibionicsSensorFault(kind: .signalImplausible))
                }
            }
        }
        if state.sensorFault != nil {
            recordForwardingOutcome(forSequence: sequence, wasForwarded: false, skipReason: "Sensor failed")
            return
        }
        if plausibilityGuard.attentionActive {
            updateStatusDetail(LocalizedString(
                "Sensor data looks wrong, readings paused — if this persists, replace the sensor",
                comment: "Status: implausible streak"
            ))
            recordForwardingOutcome(forSequence: sequence, wasForwarded: false, skipReason: "Implausible data streak")
            return
        }

        // Loop consumes a 5-minute cadence. Which records qualify is decided by
        // the sensor's own index, so live and backfilled readings land on one
        // grid and can never sit a minute apart or out of order.
        guard Self.isOnForwardGrid(sequence: sequence) else {
            recordForwardingOutcome(forSequence: sequence, wasForwarded: false, skipReason: "Off the 5-min grid")
            return
        }

        let loopCondition: GlucoseCondition?
        switch sample.condition {
        case .belowRange?: loopCondition = .belowRange
        case .aboveRange?: loopCondition = .aboveRange
        case nil: loopCondition = nil
        }

        let newSample = NewGlucoseSample(
            date: sample.date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: sample.valueMgDL),
            condition: loopCondition,
            trend: SibionicsGlucoseDisplay.mapTrend(sample.trend),
            trendRate: sample.rateOfChangeMgDLPerMinute.map {
                LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
            },
            isDisplayOnly: false,
            wasUserEntered: false,
            syncIdentifier: "sibionics-\(state.mac ?? "unknown")-\(sequence)",
            syncVersion: 1,
            device: device
        )

        logger.debug("forwarding \(Int(value)) mg/dL seq=\(sequence) source=\(sample.source)")
        var stamped = state
        if sample.source != .historicalBackfill {
            stamped.latestSample = sample.withForwardingOutcome(wasForwarded: true, skipReason: nil)
        }
        setState(stamped)
        recordForwardingOutcome(forSequence: sequence, wasForwarded: true, skipReason: nil)

        if sample.source == .historicalBackfill {
            pendingBackfillSamples.append(newSample)
        } else {
            flushPendingBackfill()
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData([newSample]))
            }
        }
        updateStatusDetail(nil)
    }

    @MainActor func flushPendingBackfill() {
        guard !pendingBackfillSamples.isEmpty else { return }
        let batch = pendingBackfillSamples
        pendingBackfillSamples.removeAll()
        logger.debug("flushing \(batch.count) backfilled sample(s) in one batch")
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: .newData(batch))
        }
    }

    /// Requests the hole between the newest record we hold and `sequence`.
    ///
    /// One request at a time: `monitor.requestHistory` reads to the end of the
    /// batch before returning, and a second concurrent request would interleave
    /// two batches on one characteristic.
    @MainActor private func requestGapBefore(sequence: UInt16, on monitor: SibionicsSensorMonitor?) {
        guard pendingBackfillFrom == nil, let monitor else { return }
        let have = state.lastIngestedSequence ?? 0
        // The live record itself is already in hand.
        guard sequence > have &+ 1 else { return }
        let first = have &+ 1
        guard sequence > first else { return }
        // Stop *before* the live record that triggered this: asking for it again
        // re-delivers a reading that is already in hand, which shows up in Loop
        // as a duplicate at the same timestamp.
        let last = sequence &- 1
        pendingBackfillFrom = first
        Task { [weak self] in
            do {
                try await monitor.requestHistory(from: first, to: last)
            } catch {
                self?.logger.debug("backfill request failed: \(error.localizedDescription)")
            }
            await MainActor.run { self?.pendingBackfillFrom = nil }
        }
    }

    static func isWarmup(elapsedSeconds: TimeInterval?, warmup: TimeInterval?) -> Bool {
        guard let elapsedSeconds, let warmup else { return false }
        return elapsedSeconds < warmup
    }

    static func isPastWear(elapsedSeconds: TimeInterval?, activeDuration: TimeInterval?) -> Bool {
        guard let elapsedSeconds, let activeDuration else { return false }
        return elapsedSeconds >= activeDuration
    }
}
