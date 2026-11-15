import Foundation
@preconcurrency import LoopKit

public extension SibionicsCGMManager {
    enum PairingError: Error, CustomStringConvertible {
        case missingAccountID
        case service(SibionicsPairingService.Failure)

        public var description: String {
            switch self {
            case .missingAccountID:
                return "Set your Sibionics account id first."
            case let .service(failure): return failure.description
            }
        }
    }

    func discoverSensors() async throws -> [SibionicsBLECentral.DiscoveredSensor] {
        let service = pairingService ?? SibionicsPairingService()
        pairingService = service
        do {
            return try await service.discover()
        } catch let failure as SibionicsPairingService.Failure {
            throw PairingError.service(failure)
        }
    }

    /// Connects a sensor and starts ingesting.
    ///
    /// Whether the sensor gets activated is decided by the sensor, not by a
    /// setting: `F0 03` answers with `activation_time`, and only a positive zero
    /// means factory-new. Anything else is attached read-only.
    @MainActor func pairSensor(
        peripheralID: UUID,
        /// Optional: the sensor's serial number characteristic supplies the MAC
        /// when this is nil, which is the normal case.
        mac: String? = nil,
        /// Product serial from an applicator tag, verified against the sensor.
        expectedSerial: String? = nil,
        onStage: @Sendable @escaping (SibionicsPairingService.Stage) -> Void = { _ in }
    ) async throws {
        // Uses the stored id, or generates one. Generation is safe even for a
        // sensor bound elsewhere: nothing is written until auth has succeeded.
        let account = ensureAccountID()

        let service = pairingService ?? SibionicsPairingService()
        pairingService = service

        let outcome: SibionicsPairingService.Outcome
        do {
            outcome = try await service.attach(
                peripheralID: peripheralID,
                mac: mac,
                accountID: account,
                registrationKey: state.registrationKey,
                warmup: state.warmup,
                activeDuration: state.activeDuration,
                expectedSerial: expectedSerial,
                onStage: onStage
            )
        } catch let failure as SibionicsPairingService.Failure {
            throw PairingError.service(failure)
        }

        var updated = state
        updated.resetSensorSession()
        plausibilityGuard = SibionicsPlausibilityGuard()
        updated.sensors.adopt(
            SibionicsSensorRecord(
                deviceInfo: outcome.deviceInfo,
                peripheralID: outcome.monitor.session.peripheralID,
                activatedAt: outcome.activatedAt,
                serial: outcome.serial ?? expectedSerial,
                registrationKey: state.registrationKey
            )
        )
        setState(updated)
        emitSensorStartEvent(for: updated)
        // A brand-new sensor has no history worth fetching, and an existing one
        // is starting live; backfill begins from the next gap.
        adopt(monitor: outcome.monitor, historyFrom: nil)
    }

    @MainActor func emitSensorStartEvent(for newState: CGMManagerState) {
        guard let mac = newState.mac else { return }
        let event = PersistedCgmEvent(
            date: newState.activatedAt ?? Date(),
            type: .sensorStart,
            deviceIdentifier: mac,
            expectedLifetime: newState.activeDuration,
            warmupPeriod: newState.warmup
        )
        logger.debug("emitting CgmEvent .sensorStart deviceIdentifier=\(SibionicsRedact.mac(mac))")
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManager(self, hasNew: [event])
        }
    }

    var canStartSensor: Bool { state.mac == nil && accountID != nil }
}
