import Foundation
@preconcurrency import LoopKit

/// Reconnect policy is the host's (OS-AID Open: Q2): the engine reports link
/// loss and signal loss; this decides when to try again.
extension SibionicsCGMManager {
    static let reconnectBackoffSeconds: [TimeInterval] = [2, 5, 10, 20, 40, 80, 160, 300]

    static func reconnectBackoff(failures: Int) -> TimeInterval {
        reconnectBackoffSeconds[min(max(failures, 0), reconnectBackoffSeconds.count - 1)]
    }

    @MainActor func linkUp() {
        startAlertTicker()
        engineConnected = true
        connectedAt = Date()
        updateStatusDetail(nil)
    }

    /// `Status` reconnects with the engine's stored session. An engine with no
    /// session (the first run of this build on a pairing made by the Swift
    /// driver) is paired again from the app's state: same peripheral, same
    /// account id, known start time, so `0x35` is never written. Then the
    /// readings missed since the watermark are fetched.
    @MainActor func scheduleReconnect() {
        guard !isDeleted, !hasLiveLink, reconnectAttempt == nil,
              credentialPairings == 0, !credentialRefused else { return }
        guard let record = state.sensors.active, let peripheralID = record.peripheralID else {
            if state.mac != nil {
                updateStatusDetail(LocalizedString(
                    "Re-pair this sensor: its Bluetooth handle was not saved.",
                    comment: "Status: missing peripheral id"
                ))
            }
            return
        }
        isReconnecting = true
        reconnectAttempt = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isReconnecting = false
                self.reconnectAttempt = nil
            }
            // Taken before the handshake: `.status` delivers the sensor's cached
            // latest record as live, which moves the watermark past the gap.
            let resumeAfter = self.state.lastIngestedSequence
            var failures = 0
            while !Task.isCancelled, !self.isDeleted, !self.hasLiveLink {
                do {
                    let host = try self.engineHost()
                    host.register(peripheralID)
                    let outcome = try await self.run(.status)
                    switch outcome {
                    case .completed:
                        self.linkUp()
                    case .refused(.notPaired):
                        try await self.pair(
                            peripheralID: peripheralID, expectedSerial: nil,
                            knownActivation: record.activatedAt, onStage: { _ in }
                        )
                    default:
                        throw PairingError.driver(Self.describe(outcome))
                    }
                    self.backfill(after: resumeAfter ?? self.state.lastIngestedSequence)
                    self.logger.debug("reconnect succeeded after \(failures) failure(s)")
                    return
                } catch {
                    failures += 1
                    let backoff = Self.reconnectBackoff(failures: failures)
                    self.logger.debug("reconnect attempt \(failures) failed: \(error)")
                    self.updateStatusDetail(String(describing: error))
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
        }
    }

    @MainActor func cancelReconnect() {
        reconnectAttempt?.cancel()
        reconnectAttempt = nil
    }

    @MainActor func handleLinkLost() {
        engineConnected = false
        connectedAt = nil
        flushPendingBackfill()
        guard !isDeleted else { return }
        scheduleReconnect()
    }

    /// Drops the link and forgets nothing.
    @MainActor func dropLink() {
        cancelReconnect()
        engine?.stop()
        engine?.disconnect()
        engineConnected = false
        connectedAt = nil
    }

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
}
