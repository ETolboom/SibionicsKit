import Foundation
import HealthKit
@preconcurrency import LoopKit

public final class SibionicsCGMManager: CGMManager, @unchecked Sendable {
    public static let pluginIdentifier = "SibionicsCGMManager"
    public static let localizedTitle = "Sibionics GS3"
    public static let healthKitStorageDelay: TimeInterval = 0

    public var localizedTitle: String { Self.localizedTitle }
    public var pluginIdentifier: String { Self.pluginIdentifier }
    public func markAsDepedency(_: Bool) {}

    public weak var cgmManagerDelegate: CGMManagerDelegate?
    public var delegateQueue: DispatchQueue!

    public internal(set) var state: CGMManagerState
    public var rawState: SibionicsCGMManager.RawStateValue { state.rawValue }

    /// The account id, mirrored from the Keychain on init.
    public internal(set) var accountID: String? {
        didSet { notifyStateObservers() }
    }

    var monitor: SibionicsSensorMonitor? {
        // Alert evaluation is driven by `setState` and the ticker: this setter
        // runs from non-isolated code, and the monitor coming or going always
        // comes with a state change anyway.
        didSet { notifyStateObservers() }
    }

    /// A link to the sensor is up. Read by the UI for the status row.
    public var hasLiveLink: Bool { monitor != nil }

    internal let logger = SibionicsLogger(category: "CgmManager")

    var pairingService: SibionicsPairingService?
    public internal(set) var connectedAt: Date? { didSet { notifyStateObservers() } }
    var reconnectAttempt: Task<Void, Never>?
    private(set) var isDeleted = false

    /// Alert bookkeeping for `CGMManager+Alerts`.
    var raisedAlerts: Set<SibionicsAlert> = []
    var alertTicker: Task<Void, Never>?

    var pendingBackfillFrom: UInt16?
    var pendingBackfillSamples: [NewGlucoseSample] = []
    var plausibilityGuard = SibionicsPlausibilityGuard()

    public var latestSample: GlucoseSample? { state.latestSample }

    public private(set) var recentSamples: [GlucoseSample] {
        get {
            recentSamplesLock.lock()
            defer { recentSamplesLock.unlock() }
            return _recentSamples
        }
        set {
            recentSamplesLock.lock()
            _recentSamples = newValue
            recentSamplesLock.unlock()
        }
    }

    private var _recentSamples: [GlucoseSample] = []
    private let recentSamplesLock = NSLock()
    private static let recentSamplesCap = 100

    let stateObservers = SibionicsWeakObserverSet<SibionicsStateObserver>()

    public internal(set) var statusDetail: String? { didSet { notifyStateObservers() } }
    public func updateStatusDetail(_ text: String?) {
        if Thread.isMainThread { statusDetail = text }
        else { DispatchQueue.main.async { [weak self] in self?.statusDetail = text } }
    }

    public internal(set) var isReconnecting = false { didSet { notifyStateObservers() } }

    // MARK: - DeviceManager / CGMManager surface

    public let isOnboarded = true
    public var appURL: URL? { nil }
    public var providesBLEHeartbeat: Bool { true }
    public var shouldSyncToRemoteService: Bool { true }
    public var managedDataInterval: TimeInterval? { nil }

    public var inSignalLoss: Bool {
        guard state.mac != nil else { return false }
        return !hasLiveLink
    }

    public var isInoperable: Bool { state.sensorNeedsReplacement }

    public var inSensorWarmup: Bool {
        if case .warmup = sensorLifecycle { return true }
        return false
    }

    public var sensorExpirationDate: Date? {
        guard let activatedAt = state.activatedAt else { return nil }
        return activatedAt.addingTimeInterval(state.activeDuration)
    }

    /// End of the warmup window, for the home screen's "warming up until" row.
    public var sensorWarmupEndDate: Date? {
        guard let activatedAt = state.activatedAt else { return nil }
        return activatedAt.addingTimeInterval(state.warmup)
    }

    public var sensorAge: TimeInterval? {
        SibionicsSensorLifecycle.age(activatedAt: state.activatedAt, sensorAge: nil)
    }

    public var sensorLifecycle: SibionicsSensorLifecycle {
        SibionicsSensorLifecycle.compute(
            sensorPaired: state.mac != nil,
            activatedAt: state.activatedAt,
            latestReadingAt: state.latestReadingTimestamp,
            hasLiveMonitor: hasLiveLink,
            reportedFault: state.sensorFault,
            activeDuration: state.activeDuration,
            warmupDuration: state.warmup
        )
    }

    public var glucoseDisplay: GlucoseDisplayable? {
        guard let sample = state.latestSample else { return nil }
        guard abs(Date().timeIntervalSince(sample.date)) <= SibionicsSensorLifecycle.signalLostThreshold else {
            return nil
        }
        return SibionicsGlucoseDisplay(sample: sample)
    }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(
            hasValidSensorSession: state.mac != nil && !state.sensorNeedsReplacement,
            inSensorWarmup: inSensorWarmup,
            isInoperable: isInoperable,
            lastCommunicationDate: state.latestReadingTimestamp,
            device: device
        )
    }

    public var device: HKDevice? {
        HKDevice(
            name: "Sibionics GS3",
            manufacturer: "Sibionics",
            model: "GS3",
            hardwareVersion: nil,
            firmwareVersion: state.sensors.active?.deviceInfo.softwareRevision,
            softwareVersion: nil,
            localIdentifier: state.mac,
            udiDeviceIdentifier: nil
        )
    }

    public var debugDescription: String {
        """
        ## SibionicsCGMManager
        \(state.debugDescription)
        * hasLiveLink: \(hasLiveLink)
        """
    }

    // MARK: - Init

    public convenience init() {
        self.init(initialState: CGMManagerState())
    }

    public required convenience init?(rawState: SibionicsCGMManager.RawStateValue) {
        self.init(initialState: CGMManagerState(rawValue: rawState) ?? CGMManagerState())
    }

    private init(initialState: CGMManagerState) {
        state = initialState
        recentSamples = initialState.recentSamples
        accountID = initialState.accountID ?? SibionicsKeychain.loadAccountID()
        pairingService = SibionicsPairingService()
        if state.mac != nil {
            Task { @MainActor in self.scheduleReconnect() }
        }
    }

    // MARK: - CGMManager

    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // The sensor pushes on its own; there is nothing to poll. A tick
            // while the link is down is a good moment to retry it.
            if !self.hasLiveLink, self.state.mac != nil {
                self.scheduleReconnect()
            }
        }
        completion(.noData)
    }

    public func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier) async throws {}
    public func getSoundBaseURL() -> URL? { nil }
    public func getSounds() -> [Alert.Sound] { [] }

    private let statusObservers = WeakSynchronizedSet<CGMManagerStatusObserver>()
    public func addStatusObserver(_ observer: CGMManagerStatusObserver, queue: DispatchQueue) {
        statusObservers.insert(observer, queue: queue)
    }

    public func removeStatusObserver(_ observer: CGMManagerStatusObserver) {
        statusObservers.removeElement(observer)
    }

    private func notifyStatusObservers() {
        let status = cgmManagerStatus
        statusObservers.forEach { $0.cgmManager(self, didUpdate: status) }
    }

    @MainActor public func delete() async {
        isDeleted = true
        cancelReconnect()
        logger.info("cgm delete: releasing BLE link")
        stopAlertTicker()
        monitor?.disconnect()
        monitor = nil
        await cgmManagerDelegate?.cgmManagerWantsDeletion(self)
    }

    @MainActor public func discardSensor() {
        cancelReconnect()
        logger.info("discard sensor: releasing BLE link (mac=\(SibionicsRedact.mac(state.mac)))")
        monitor?.disconnect()
        monitor = nil
        isReconnecting = false
        stopAlertTicker()
        recentSamples = []
        plausibilityGuard = SibionicsPlausibilityGuard()
        pendingBackfillFrom = nil
        pendingBackfillSamples = []

        if let mac = state.mac {
            let event = PersistedCgmEvent(date: Date(), type: .sensorEnd, deviceIdentifier: mac)
            delegateQueue?.async { [weak self] in
                guard let self else { return }
                self.cgmManagerDelegate?.cgmManager(self, hasNew: [event])
            }
        }
        clearState()
    }

    @MainActor private func clearState() {
        var blank = state
        blank.sensors.discardActive()
        blank.resetSensorSession()
        setState(blank)
    }

    @MainActor func setState(_ newState: CGMManagerState) {
        state = newState
        recentSamples = newState.recentSamples
        delegateQueue?.async { [weak self] in
            guard let self else { return }
            self.cgmManagerDelegate?.cgmManagerDidUpdateState(self)
        }
        notifyStateObservers()
        notifyStatusObservers()
        evaluateAlerts()
    }

    @MainActor func recordSample(_ sample: GlucoseSample) {
        recentSamplesLock.lock()
        // Newest-first by the reading's own timestamp: a backfilled record
        // always arrives after the live record that triggered the request.
        let index = _recentSamples.firstIndex { $0.date <= sample.date } ?? _recentSamples.count
        _recentSamples.insert(sample, at: index)
        if _recentSamples.count > Self.recentSamplesCap {
            _recentSamples.removeLast(_recentSamples.count - Self.recentSamplesCap)
        }
        let persisted = Array(_recentSamples.prefix(CGMManagerState.recentSamplesPersistenceCap))
        recentSamplesLock.unlock()
        var updated = state
        updated.recentSamples = persisted
        setState(updated)
    }

    @MainActor func recordForwardingOutcome(forSequence sequence: UInt16, wasForwarded: Bool, skipReason: String?) {
        recentSamplesLock.lock()
        guard let index = _recentSamples.firstIndex(where: { $0.sequence == sequence }) else {
            recentSamplesLock.unlock()
            return
        }
        _recentSamples[index] = _recentSamples[index].withForwardingOutcome(
            wasForwarded: wasForwarded, skipReason: skipReason
        )
        let persisted = Array(_recentSamples.prefix(CGMManagerState.recentSamplesPersistenceCap))
        recentSamplesLock.unlock()
        var updated = state
        updated.recentSamples = persisted
        setState(updated)
    }

    // MARK: - Account

    /// The account id the driver will authenticate with, generating one on
    /// first use.
    ///
    /// There is nothing to log in to. V3 has no separate bind step, so the
    /// activation frame's account id *is* the binding: a sensor in its factory
    /// state takes whatever it is first given, and a value this driver picked is
    /// therefore one it already knows. Only a sensor that the official app
    /// activated needs an id from outside, and then it needs exactly one thing —
    /// the value that app used.
    @MainActor public func ensureAccountID() -> SibionicsAccountID {
        if let stored = accountID, let parsed = try? SibionicsAccountID(stored) {
            return parsed
        }
        let generated = SibionicsAccountID.generated()
        SibionicsKeychain.saveAccountID(generated.string)
        accountID = generated.string
        var updated = state
        updated.accountID = generated.string
        setState(updated)
        logger.info("generated a local account id (nothing was fetched); it is stored in the Keychain")
        return generated.id
    }

    /// The account id is the only per-user secret in the protocol. It is set
    /// from pairing (or by hand in Settings) and validated by re-encoding it.
    ///
    /// This is the escape hatch for moving a sensor that the official app
    /// activated: the sensor compares this value and nothing else, so entering
    /// the id that app used is all that "moving" it requires. Nothing is written
    /// to the sensor either way — see `reauthenticateAfterCredentialChange`.
    @MainActor public func setAccountID(_ id: String?) throws {
        let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            SibionicsKeychain.deleteAccountID()
            accountID = nil
            var updated = state
            updated.accountID = nil
            setState(updated)
        } else {
            _ = try SibionicsAccountID(trimmed)
            SibionicsKeychain.saveAccountID(trimmed)
            accountID = trimmed
            var updated = state
            updated.accountID = trimmed
            setState(updated)
        }
        reauthenticateAfterCredentialChange()
    }

    /// Credentials changed, so the live link is authenticating with the wrong
    /// ones. Dropping it makes the normal reconnect loop try again; nothing is
    /// written to the sensor by doing so.
    @MainActor func reauthenticateAfterCredentialChange() {
        guard state.mac != nil else { return }
        if let monitor {
            logger.info("credentials changed; reconnecting to re-authenticate")
            monitor.disconnect()
        } else {
            scheduleReconnect()
        }
    }
}

// MARK: - Display

struct SibionicsGlucoseDisplay: GlucoseDisplayable {
    let sample: GlucoseSample

    var isStateValid: Bool { !sample.hasBlockingIssue }
    var isLocal: Bool { true }
    var glucoseRangeCategory: GlucoseRangeCategory? { nil }
    var trendType: GlucoseTrend? { Self.mapTrend(sample.trend) }

    static func mapTrend(_ trend: GlucoseSample.Trend) -> GlucoseTrend? {
        switch trend {
        case .notDetermined: return nil
        case .fallingQuickly: return .downDown
        case .falling: return .down
        case .stable: return .flat
        case .rising: return .up
        case .risingQuickly: return .upUp
        }
    }

    var trendRate: LoopQuantity? {
        sample.rateOfChangeMgDLPerMinute.map {
            LoopQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
        }
    }
}

// MARK: - Observers

public protocol SibionicsStateObserver: AnyObject {
    func sibionicsCGMManager(
        _ manager: SibionicsCGMManager,
        didUpdate state: CGMManagerState,
        latestSample: GlucoseSample?
    )
}

public extension SibionicsCGMManager {
    func addStateObserver(_ observer: SibionicsStateObserver) { stateObservers.add(observer) }
    func removeStateObserver(_ observer: SibionicsStateObserver) { stateObservers.remove(observer) }

    internal func notifyStateObservers() {
        let manager = self
        stateObservers.notify { observer in
            observer.sibionicsCGMManager(manager, didUpdate: manager.state, latestSample: manager.latestSample)
        }
    }
}

final class SibionicsWeakObserverSet<Observer> {
    private let lock = NSLock()
    private var observers: [WeakBox] = []
    private struct WeakBox { weak var ref: AnyObject? }

    func add(_ observer: Observer) {
        let ref = observer as AnyObject
        lock.lock()
        observers.removeAll { $0.ref === ref || $0.ref == nil }
        observers.append(WeakBox(ref: ref))
        lock.unlock()
    }

    func remove(_ observer: Observer) {
        let ref = observer as AnyObject
        lock.lock()
        observers.removeAll { $0.ref === ref || $0.ref == nil }
        lock.unlock()
    }

    func notify(_ body: @escaping (Observer) -> Void) {
        lock.lock()
        let snapshot = observers.compactMap { $0.ref as? Observer }
        observers.removeAll { $0.ref == nil }
        lock.unlock()
        DispatchQueue.main.async { for observer in snapshot { body(observer) } }
    }
}
