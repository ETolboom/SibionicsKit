import Foundation
@preconcurrency import LoopKit

extension SibionicsCGMManager {
    @MainActor func adopt(monitor: SibionicsSensorMonitor, historyFrom: UInt16? = nil) {
        guard !isDeleted else {
            monitor.stop()
            return
        }
        logger.debug("adopting monitor mac=\(SibionicsRedact.mac(state.mac))")
        startAlertTicker()
        // A replaced monitor's stale watchdog would keep forcing disconnects on
        // the same peripheral, and a still-connected one holds a zombie link.
        self.monitor?.disconnect()
        self.monitor = monitor
        connectedAt = Date()

        var updated = state
        updated.sensors.update { $0.peripheralID = monitor.session.peripheralID }
        setState(updated)

        monitor.setHandlers(
            onReading: { [weak self] reading in
                Task { @MainActor in self?.ingest(reading) }
            },
            onDisconnect: { [weak self, weak monitor] in
                guard let monitor else { return }
                Task { @MainActor in self?.handleMonitorDisconnect(monitor) }
            },
            onStatus: { [weak self] text in self?.updateStatusDetail(text) },
            onBackfillComplete: { [weak self] in
                Task { @MainActor in self?.flushPendingBackfill() }
            },
            onRecordSeen: { [weak self] index, isHistorical in
                Task { @MainActor in self?.noteRecordSeen(index, isHistorical: isHistorical) }
            },
            onActivationLearned: { [weak self] date in
                Task { @MainActor in self?.persistActivation(date) }
            }
        )

        // Handlers are installed, so it is safe to start reading now.
        Task { await monitor.run(historyFrom: historyFrom) }
    }

    /// The start time can be learned after the fact — a moved sensor whose clock
    /// query went unanswered gets it from the first record. Persist it so the
    /// lifecycle, warmup gate and expiry all work from then on.
    @MainActor func persistActivation(_ date: Date) {
        guard !isDeleted else { return }
        let existing = state.activatedAt
        guard existing == nil || abs(existing!.timeIntervalSince(date)) > 30 else { return }
        logger.info("learned the sensor start time: \(date)")
        var updated = state
        updated.sensors.update { $0.activatedAt = date }
        setState(updated)
    }

    @MainActor func markSensorFailed(_ fault: SibionicsSensorFault) {
        guard !isDeleted, state.sensorFault == nil else { return }
        logger.error("marking sensor as needing replacement: \(fault.kind)")
        var updated = state
        updated.sensorFault = fault.kind
        setState(updated)
        updateStatusDetail(SibionicsSensorLifecycle.faultDetail(for: fault.kind))
    }

    @MainActor private func handleMonitorDisconnect(_ monitor: SibionicsSensorMonitor) {
        // A replaced monitor's stream can end late; only the current one may
        // tear things down.
        guard self.monitor === monitor else { return }
        flushPendingBackfill()
        self.monitor = nil
        monitor.stop()
        connectedAt = nil
        guard !isDeleted else { return }
        logger.debug("monitor disconnect; scheduling reconnect")
        scheduleReconnect()
    }

    static let reconnectBackoffSeconds: [TimeInterval] = [2, 5, 10, 20, 40, 80, 160, 300]

    static func reconnectBackoff(failures: Int) -> TimeInterval {
        reconnectBackoffSeconds[min(max(failures, 0), reconnectBackoffSeconds.count - 1)]
    }

    @MainActor func scheduleReconnect() {
        guard !isDeleted, !hasLiveLink else { return }
        guard let record = state.sensors.active else { return }
        guard reconnectAttempt == nil else { return }

        guard let accountID, let parsed = try? SibionicsAccountID(accountID) else {
            logger.debug("reconnect: no account id set; skipping")
            updateStatusDetail(LocalizedString(
                "Add your Sibionics account id to reconnect.",
                comment: "Status: missing account id"
            ))
            return
        }
        // iOS keeps the peripheral identifier stable per sensor per phone, so a
        // reconnect never has to scan or decode an advertisement. Without it the
        // sensor must be re-paired, which is why pairing always persists it.
        guard let peripheralID = record.peripheralID else {
            logger.error("reconnect: no stored peripheral id; a re-pair is required")
            updateStatusDetail(LocalizedString(
                "Re-pair this sensor: its Bluetooth handle was not saved.",
                comment: "Status: missing peripheral id"
            ))
            return
        }

        let mac = record.deviceInfo.mac
        let registrationKey = record.registrationKey
        let warmup = state.warmup
        let activeDuration = state.activeDuration
        let historyFrom = state.lastIngestedSequence.map { $0 &+ 1 }

        isReconnecting = true
        reconnectAttempt = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isReconnecting = false
                self.reconnectAttempt = nil
            }
            var failures = 0
            while !Task.isCancelled, !self.isDeleted, self.monitor == nil {
                do {
                    let service = self.pairingService ?? SibionicsPairingService()
                    self.pairingService = service
                    let outcome = try await service.attach(
                        peripheralID: peripheralID,
                        mac: mac,
                        accountID: parsed,
                        registrationKey: registrationKey,
                        warmup: warmup,
                        activeDuration: activeDuration,
                        knownActivatedAt: record.activatedAt
                    )
                    self.adopt(monitor: outcome.monitor, historyFrom: historyFrom)
                    // The sensor is the authority on when it started; keep the
                    // persisted copy in sync if the two disagree.
                    if outcome.activatedAt != self.state.activatedAt {
                        var updated = self.state
                        updated.sensors.update { $0.activatedAt = outcome.activatedAt }
                        self.setState(updated)
                    }
                    self.logger.debug("reconnect succeeded after \(failures) failure(s)")
                    self.updateStatusDetail(nil)
                    return
                } catch {
                    failures += 1
                    let backoff = Self.reconnectBackoff(failures: failures)
                    self.logger.debug("reconnect attempt \(failures) failed: \(error.localizedDescription)")
                    self.updateStatusDetail(error.localizedDescription)
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
        }
    }

    @MainActor func cancelReconnect() {
        reconnectAttempt?.cancel()
        reconnectAttempt = nil
    }
}
