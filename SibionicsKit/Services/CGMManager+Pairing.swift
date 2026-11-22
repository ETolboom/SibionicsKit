import Foundation
@preconcurrency import LoopKit

/// Pairing through the Rust engine (`CgmCommand::Pair`). The engine connects,
/// authenticates, checks the applicator serial, reads the sensor clock and
/// starts the sensor only if it reports it was never started. It creates an
/// account id when the app has none; the app keeps the one it reports.
public extension SibionicsCGMManager {
    enum PairingError: Error, CustomStringConvertible {
        case missingAccountID
        case accountRefused
        case driver(String)

        public var description: String {
            switch self {
            case .missingAccountID: return "Set your Sibionics account id first."
            case .accountRefused: return SibionicsCGMManager.describe(FfiOutcome.failed(failure: .keyRejected))
            case let .driver(detail): return detail
            }
        }
    }

    func discoverSensors() async throws -> [SibionicsBLECentral.DiscoveredSensor] {
        do {
            return try await SibionicsBLECentral.shared.discoverSensors()
        } catch {
            throw PairingError.driver(error.localizedDescription)
        }
    }

    /// `mac` is not needed: the engine reads it from the sensor (`0x2A25`).
    @MainActor func pairSensor(
        peripheralID: UUID,
        mac _: String? = nil,
        expectedSerial: String? = nil,
        onStage: @Sendable @escaping (SibionicsPairingStage) -> Void = { _ in }
    ) async throws {
        try await pair(peripheralID: peripheralID, expectedSerial: expectedSerial, knownActivation: nil, onStage: onStage)
    }

    /// `knownActivation` is set when re-pairing a sensor the app already
    /// knows (reconnect without an engine session, a changed account id):
    /// its readings and watermark are kept.
    @MainActor internal func pair(
        peripheralID: UUID,
        expectedSerial: String?,
        knownActivation: Date?,
        onStage: @Sendable @escaping (SibionicsPairingStage) -> Void
    ) async throws {
        let host = try engineHost()
        let address = host.register(peripheralID)
        onStage(.connecting)
        let outcome = try await run(.pair(
            address: address,
            credential: accountID.map { Data($0.utf8) },
            expectedSerial: expectedSerial,
            knownActivationMs: knownActivation.map { UInt64($0.timeIntervalSince1970 * 1000) }
        ))
        if case .failed(.keyRejected) = outcome { throw PairingError.accountRefused }
        guard case let .completed(.paired(report)) = outcome else {
            throw PairingError.driver(Self.describe(outcome))
        }
        onStage(.startingSession)
        setAccountRefused(false)
        if let credential = String(data: report.credential, encoding: .utf8), credential != accountID {
            SibionicsKeychain.saveAccountID(credential)
            accountID = credential
        }
        let activatedAt = report.activationMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
        let info = engineDeviceInfo
        let firmware = info?.firmware ?? ""
        var updated = state
        let samePairing = knownActivation != nil && state.peripheralID == peripheralID
        if !samePairing { updated.resetSensorSession() }
        updated.sensors.adopt(
            SibionicsSensorRecord(
                deviceInfo: SibionicsDeviceInfo(
                    mac: info?.serial ?? state.mac ?? "",
                    model: info?.model,
                    serial: report.productSerial ?? expectedSerial,
                    softwareRevision: firmware,
                    protocolGeneration: .v3,
                    region: SibionicsProtocolVersion(softwareRevision: firmware, manufacturer: info?.manufacturer ?? "").region,
                    warmup: state.warmup,
                    activeDuration: state.activeDuration
                ),
                peripheralID: peripheralID,
                activatedAt: activatedAt,
                serial: report.productSerial ?? expectedSerial ?? state.sensors.active?.serial,
                registrationKey: state.activeRegistrationKey
            )
        )
        setState(updated)
        if !samePairing { emitSensorStartEvent(for: updated) }
        linkUp()
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

    var canStartSensor: Bool { state.mac == nil }
}
