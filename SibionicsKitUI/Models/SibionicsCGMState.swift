import Combine
import Foundation
import SibionicsKit
import SwiftUI

/// Thin observable bridge between the manager's state and SwiftUI.
@MainActor
public final class SibionicsCGMState: ObservableObject {
    @Published public private(set) var managerState: CGMManagerState
    @Published public private(set) var latestSample: GlucoseSample?
    @Published public private(set) var lifecycle: SibionicsSensorLifecycle = .noSensor
    @Published public private(set) var statusDetail: String?
    @Published public private(set) var communicationError: String?

    private weak var manager: SibionicsCGMManager?
    private var pollTimer: Timer?

    public init(manager: SibionicsCGMManager) {
        self.manager = manager
        managerState = manager.state
        latestSample = manager.latestSample
        lifecycle = manager.sensorLifecycle
        statusDetail = manager.statusDetail
        communicationError = manager.communicationError
        manager.addStateObserver(self)
        // `sensorLifecycle` is time-derived (warmup ends, readings go stale), so
        // it has to be re-read even when nothing changed.
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDerived() }
        }
        pollTimer = timer
    }

    deinit {
        pollTimer?.invalidate()
    }

    public var mac: String? { managerState.mac }
    public var sensorSerial: String? { managerState.sensors.active?.serial }
    public var sensorModel: String { managerState.sensors.active?.deviceInfo.model ?? "GS3" }
    public var sensorFirmware: String? { managerState.sensors.active?.deviceInfo.softwareRevision }
    public var activatedAt: Date? { managerState.sensors.active?.activatedAt }
    public var expirationDate: Date? { manager?.sensorExpirationDate }
    public var hasSensor: Bool { managerState.mac != nil }
    public var accountID: String? { manager?.accountID }
    public var warmup: TimeInterval { managerState.warmup }
    public var activeDuration: TimeInterval { managerState.activeDuration }
    public var recentSamples: [GlucoseSample] { manager?.recentSamples ?? [] }
    public var connected: Bool { manager?.hasLiveLink ?? false }
    public var isReconnecting: Bool { manager?.isReconnecting ?? false }

    public var sensorAgeDescription: String? {
        guard let age = manager?.sensorAge, age >= 0 else { return nil }
        let days = Int(age) / 86400
        let hours = (Int(age) % 86400) / 3600
        return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \((Int(age) % 3600) / 60)m"
    }

    private func refreshDerived() {
        guard let manager else { return }
        managerState = manager.state
        latestSample = manager.latestSample
        lifecycle = manager.sensorLifecycle
        statusDetail = manager.statusDetail
        communicationError = manager.communicationError
    }

    public func setAccountID(_ id: String) throws {
        try manager?.setAccountID(id)
        refreshDerived()
    }

    public var registrationKey: Data { manager?.state.registrationKey ?? SibionicsRegistrationKey.default }

    public func setRegistrationKey(_ key: Data) {
        manager?.setRegistrationKey(key)
        refreshDerived()
    }

    public func pair(
        peripheralID: UUID,
        mac: String?,
        expectedSerial: String? = nil,
        onStage: @Sendable @escaping (SibionicsPairingStage) -> Void
    ) async throws {
        try await manager?.pairSensor(
            peripheralID: peripheralID, mac: mac, expectedSerial: expectedSerial,
            onStage: onStage
        )
        refreshDerived()
    }

    public func discover() async throws -> [SibionicsBLECentral.DiscoveredSensor] {
        guard let manager else { return [] }
        return try await manager.discoverSensors()
    }

    /// Stops reading and forgets the pairing, but leaves the CGM installed. The
    /// sensor itself keeps running its own wear.
    public func endSensor() {
        manager?.discardSensor()
        refreshDerived()
    }

    /// Removes the CGM from the app entirely. Distinct from `endSensor()`: the
    /// entry goes away, so this is the destructive one.
    public func deleteCGM() {
        guard let manager else { return }
        Task { await manager.delete() }
    }

    public func logFiles() -> [URL] { SibionicsLogger.logFiles() }
}

extension SibionicsCGMState: SibionicsStateObserver {
    public func sibionicsCGMManager(
        _: SibionicsCGMManager,
        didUpdate _: CGMManagerState,
        latestSample _: GlucoseSample?
    ) {
        Task { @MainActor in self.refreshDerived() }
    }
}
