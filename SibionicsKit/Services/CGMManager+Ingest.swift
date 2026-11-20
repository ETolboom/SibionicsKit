import Foundation
@preconcurrency import LoopKit

/// Readings from the engine into LoopKit.
///
/// The engine has already decided everything about a reading that every app
/// would decide the same way: its time, mg/dL value, trend, and whether it is
/// usable (`quality`: warm-up, past wear, implausible, flagged, sensor failed).
/// What is left is Trio/Loop policy: the 5-minute grid, the sync identifier,
/// batching backfill, and the manager's own state.
extension SibionicsCGMManager {
    /// Loop consumes a 5-minute cadence; which records qualify is decided by
    /// the sensor's own index, so live and backfilled readings share one grid.
    static let forwardGridStep: UInt16 = 5
    static func isOnForwardGrid(sequence: UInt16) -> Bool { sequence % forwardGridStep == 0 }

    /// `cgm_shared::Quality` bits (`FfiReading.quality`).
    enum Quality {
        static let warmup: UInt8 = 1 << 0
        static let expired: UInt8 = 1 << 1
        static let implausible: UInt8 = 1 << 2
        static let deviceFlagged: UInt8 = 1 << 3
        static let sensorFailed: UInt8 = 1 << 4
    }

    static func trend(_ trend: FfiTrend?) -> GlucoseSample.Trend {
        switch trend {
        case .fallingQuickly?: return .fallingQuickly
        case .falling?: return .falling
        case .stable?: return .stable
        case .rising?: return .rising
        case .risingQuickly?: return .risingQuickly
        case nil: return .notDetermined
        }
    }

    static func skipReason(quality: UInt8) -> String? {
        if quality & Quality.sensorFailed != 0 { return "Sensor failed" }
        if quality & Quality.implausible != 0 { return "Implausible data streak" }
        if quality & Quality.warmup != 0 { return "Warm-up" }
        if quality & Quality.expired != 0 { return "Past wear" }
        if quality & Quality.deviceFlagged != 0 { return "Flagged by the sensor" }
        return nil
    }

    @MainActor func ingest(_ reading: FfiReading) {
        let sequence = UInt16(clamping: reading.sequence)
        // Every index counts toward the watermark, including the four in five
        // that carry no value (`0xFF01`), so they are not asked for again.
        noteRecordSeen(sequence, isHistorical: reading.historical)
        if state.sensorNeedsReplacement {
            logger.debug("sensor marked for replacement; dropping seq=\(sequence)")
            return
        }
        guard let mgdl = reading.mgdl else { return }

        let date = Date(timeIntervalSince1970: TimeInterval(reading.timeMs) / 1000)
        let trend = Self.trend(reading.trend)
        let value = Double(mgdl)
        let sample = GlucoseSample(
            date: date,
            valueMgDL: value,
            trend: trend,
            rateOfChangeMgDLPerMinute: reading.rateDeciMgdlPerMin.map { Double($0) / 10 },
            sequence: sequence,
            rawDisplayMgDL: value,
            elapsedSeconds: state.activatedAt.map { date.timeIntervalSince($0) },
            source: reading.historical ? .historicalBackfill : .realtime
        )
        let outsideWear = reading.quality & (Quality.warmup | Quality.expired) != 0
        if !outsideWear { recordSample(sample) }

        var updated = state
        if !reading.historical, sequence >= (updated.lastIngestedSequence ?? 0) {
            updated.latestReadingTimestamp = Date()
            updated.lastIngestedSequence = sequence
        }
        setState(updated)

        if let reason = Self.skipReason(quality: reading.quality) {
            if reading.quality & Quality.implausible != 0 {
                updateStatusDetail(LocalizedString(
                    "Sensor data looks wrong, readings paused — if this persists, replace the sensor",
                    comment: "Status: implausible streak"
                ))
            }
            if !outsideWear {
                recordForwardingOutcome(forSequence: sequence, wasForwarded: false, skipReason: reason)
            }
            logger.debug("not forwarding seq=\(sequence): \(reason)")
            return
        }
        guard Self.isOnForwardGrid(sequence: sequence) else {
            recordForwardingOutcome(forSequence: sequence, wasForwarded: false, skipReason: "Off the 5-min grid")
            return
        }

        let newSample = NewGlucoseSample(
            date: date,
            quantity: LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: value),
            condition: nil,
            trend: SibionicsGlucoseDisplay.mapTrend(trend),
            trendRate: sample.rateOfChangeMgDLPerMinute.map {
                LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
            },
            isDisplayOnly: false,
            wasUserEntered: false,
            // Unchanged from the Swift driver, so Trio deduplicates across the switch.
            syncIdentifier: "sibionics-\(state.mac ?? "unknown")-\(sequence)",
            syncVersion: 1,
            device: device
        )

        logger.debug("forwarding \(Int(value)) mg/dL seq=\(sequence) source=\(sample.source)")
        var stamped = state
        if !reading.historical {
            stamped.latestSample = sample.withForwardingOutcome(wasForwarded: true, skipReason: nil)
        }
        setState(stamped)
        recordForwardingOutcome(forSequence: sequence, wasForwarded: true, skipReason: nil)

        if reading.historical {
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

    /// Fetches what the sensor holds after `after`. One request at a time: a
    /// second would interleave two batches on the shared notify characteristic.
    @MainActor func backfill(after: UInt16?) {
        guard let after, pendingBackfillFrom == nil else { return }
        pendingBackfillFrom = after &+ 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.pendingBackfillFrom = nil }
            do {
                let outcome = try await self.run(.readReadings(after: UInt32(after)))
                guard case let .completed(.readings(readings)) = outcome else {
                    self.logger.debug("backfill: \(Self.describe(outcome))")
                    return
                }
                for reading in readings { self.ingest(reading) }
                self.flushPendingBackfill()
            } catch {
                self.logger.debug("backfill failed: \(error)")
            }
        }
    }

    /// Only the live stream moves the watermark; history is always behind it.
    @MainActor func noteRecordSeen(_ index: UInt16, isHistorical: Bool) {
        guard !isHistorical, index > (state.lastIngestedSequence ?? 0) else { return }
        var updated = state
        updated.lastIngestedSequence = index
        setState(updated)
    }
}
