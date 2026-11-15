import CoreBluetooth
import Foundation

/// Scanning, connecting and state restoration.
///
/// A GS3 advertises its `FF30` service. The advertisement is the only place the
/// sensor is visible before connection, and the vendor's advert payload is not
/// fully decoded here — the driver treats the *peripheral identifier* as the
/// durable handle (iOS keeps it stable per sensor per phone) and takes the MAC
/// from the pairing record, which is what the cipher IV is derived from. That
/// means reconnects never need the advertisement at all once the sensor has
/// been seen once.
public final class SibionicsBLECentral: NSObject, @unchecked Sendable {
    public enum BLEError: Error, CustomStringConvertible {
        case bluetoothUnavailable(CBManagerState)
        case connectFailed(String)
        case disconnected(String)
        case busy
        case noSensor

        public var description: String {
            switch self {
            case let .bluetoothUnavailable(state): return "Bluetooth is unavailable (state \(state.rawValue))."
            case let .connectFailed(message): return "Could not connect to the sensor: \(message)"
            case let .disconnected(message): return "The sensor connection dropped: \(message)"
            case .busy: return "Bluetooth is busy with another sensor operation. Try again in a moment."
            case .noSensor: return "No Sibionics sensor was found."
            }
        }
    }

    public struct DiscoveredSensor: Equatable, Sendable, Identifiable {
        public let peripheralID: UUID
        public let name: String?
        public let rssi: Int
        /// Manufacturer-specific data, kept raw: the MAC is in there somewhere,
        /// but the offset is not confirmed. See `SibionicsNFC` for the
        /// pairing-record route that is actually used.
        public let manufacturerData: Data?
        public var id: UUID { peripheralID }

        public var displayName: String { name ?? peripheralID.uuidString.prefix(8).description }
    }

    private let logger = SibionicsLogger(category: "BLECentral")
    private let queue = DispatchQueue(label: "org.loopkit.SibionicsKit.ble")

    private lazy var manager = CBCentralManager(
        delegate: self,
        queue: queue,
        options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier]
    )

    public static let restorationIdentifier = "org.loopkit.SibionicsKit.central"
    public static let shared = SibionicsBLECentral()

    private var powerOnWaiters: [CheckedContinuation<Void, Error>] = []
    private var pendingConnect: PendingConnect?
    private var pendingDiscovery: PendingDiscovery?
    private weak var live: SibionicsBLEPeripheral?
    private var restoredPeripherals: [CBPeripheral] = []

    private struct PendingConnect {
        let peripheralID: UUID
        let continuation: CheckedContinuation<SibionicsBLEPeripheral, Error>
        let timeout: DispatchWorkItem
        var wrapper: SibionicsBLEPeripheral?
        var standing: CBPeripheral?
        var finished = false
    }

    private struct PendingDiscovery {
        let continuation: CheckedContinuation<[DiscoveredSensor], Error>
        var found: [UUID: DiscoveredSensor] = [:]
        let settleWindow: TimeInterval
        var settle: DispatchWorkItem?
        let timeout: DispatchWorkItem
        var finished = false
    }

    override private init() {
        super.init()
        _ = manager
    }

    // MARK: - Public API

    /// Connects to a sensor already known to iOS. This is the reconnect path:
    /// no scan, no advertisement, works even when the sensor only advertises
    /// intermittently.
    public func connect(peripheralID: UUID, scanTimeout: TimeInterval = 30) async throws -> SibionicsBLEPeripheral {
        try await ensurePoweredOn()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.pendingConnect == nil, self.pendingDiscovery == nil else {
                        continuation.resume(throwing: BLEError.busy)
                        return
                    }
                    let timeoutItem = DispatchWorkItem { [weak self] in
                        self?.failPending(BLEError.connectFailed("timed out"))
                    }
                    self.pendingConnect = PendingConnect(
                        peripheralID: peripheralID,
                        continuation: continuation,
                        timeout: timeoutItem
                    )
                    self.queue.asyncAfter(deadline: .now() + scanTimeout, execute: timeoutItem)

                    if let restored = self.restoredPeripherals.first(where: { $0.identifier == peripheralID }) {
                        self.restoredPeripherals.removeAll { $0.identifier == peripheralID }
                        self.attach(restored)
                        return
                    }
                    let known = self.manager.retrievePeripherals(withIdentifiers: [peripheralID])
                    if let peripheral = known.first {
                        self.attach(peripheral)
                        return
                    }
                    // iOS forgot the peripheral (reinstall, restore failed):
                    // fall back to a scan, which will match by identifier.
                    self.startScan(allowDuplicates: false)
                }
            }
        } onCancel: {
            self.queue.async { self.failPending(CancellationError()) }
        }
    }

    /// Scans for any advertising sensor. Used by pairing, before anything is
    /// known about the sensor.
    public func discoverSensors(
        scanTimeout: TimeInterval = 20,
        settleWindow: TimeInterval = 1.5
    ) async throws -> [DiscoveredSensor] {
        try await ensurePoweredOn()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.pendingConnect == nil, self.pendingDiscovery == nil else {
                    continuation.resume(throwing: BLEError.busy)
                    return
                }
                let timeoutItem = DispatchWorkItem { [weak self] in self?.finishDiscovery() }
                self.pendingDiscovery = PendingDiscovery(
                    continuation: continuation,
                    settleWindow: settleWindow,
                    timeout: timeoutItem
                )
                self.queue.asyncAfter(deadline: .now() + scanTimeout, execute: timeoutItem)
                self.startScan(allowDuplicates: true)
            }
        }
    }

    // MARK: - Internals

    private func startScan(allowDuplicates: Bool) {
        manager.scanForPeripherals(
            withServices: [SibionicsGATT.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
    }

    private func ensurePoweredOn() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                switch self.manager.state {
                case .poweredOn: continuation.resume()
                case .resetting,
                     .unknown: self.powerOnWaiters.append(continuation)
                default: continuation.resume(throwing: BLEError.bluetoothUnavailable(self.manager.state))
                }
            }
        }
    }

    private func attach(_ peripheral: CBPeripheral) {
        guard pendingConnect?.finished == false else { return }
        let wrapper = SibionicsBLEPeripheral(peripheral: peripheral, manager: manager, queue: queue)
        pendingConnect?.wrapper = wrapper
        let ready: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                if let wrapper = self.pendingConnect?.wrapper { self.finishPending(wrapper) }
            case let .failure(error):
                self.failPending(error)
            }
        }
        if peripheral.state == .connected {
            wrapper.beginDiscovery(completion: ready)
        } else {
            pendingConnect?.standing = peripheral
            manager.connect(peripheral, options: nil)
        }
    }

    private func finishDiscovery() {
        guard var discovery = pendingDiscovery, !discovery.finished else { return }
        discovery.finished = true
        pendingDiscovery = nil
        manager.stopScan()
        discovery.timeout.cancel()
        discovery.settle?.cancel()
        let sorted = discovery.found.values.sorted { $0.rssi > $1.rssi }
        logger.info("discovery found \(sorted.count) sensor(s)")
        discovery.continuation.resume(returning: sorted)
    }

    private func failPending(_ error: Error) {
        guard var pending = pendingConnect, !pending.finished else { return }
        pending.finished = true
        pendingConnect = pending
        manager.stopScan()
        pending.timeout.cancel()
        if let wrapper = pending.wrapper {
            manager.cancelPeripheralConnection(wrapper.peripheral)
        }
        if let standing = pending.standing, standing !== pending.wrapper?.peripheral {
            manager.cancelPeripheralConnection(standing)
        }
        pendingConnect = nil
        pending.continuation.resume(throwing: error)
    }

    private func finishPending(_ peripheral: SibionicsBLEPeripheral) {
        guard var pending = pendingConnect, !pending.finished else { return }
        pending.finished = true
        pending.timeout.cancel()
        manager.stopScan()
        if let standing = pending.standing, standing !== peripheral.peripheral {
            manager.cancelPeripheralConnection(standing)
        }
        pendingConnect = nil
        live = peripheral
        logger.info("connected \(peripheral.peripheralID.uuidString) mtu=\(peripheral.maximumWriteLength)")
        pending.continuation.resume(returning: peripheral)
    }
}

extension SibionicsBLECentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let waiters = powerOnWaiters
        powerOnWaiters = []
        switch central.state {
        case .poweredOn:
            waiters.forEach { $0.resume() }
        default:
            waiters.forEach { $0.resume(throwing: BLEError.bluetoothUnavailable(central.state)) }
            // The radio going away drops the link without a
            // didDisconnectPeripheral callback, so nothing downstream would
            // otherwise learn about it.
            if let pending = pendingConnect, !pending.finished {
                failPending(BLEError.bluetoothUnavailable(central.state))
            }
            if live != nil {
                live?.handleDisconnect()
                live = nil
            }
        }
    }

    public func centralManager(_: CBCentralManager, willRestoreState dict: [String: Any]) {
        let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        restoredPeripherals = peripherals
        logger.info("state restoration: \(peripherals.count) peripheral(s)")
        if let pending = pendingConnect, !pending.finished,
           let restored = peripherals.first(where: { $0.identifier == pending.peripheralID })
        {
            restoredPeripherals.removeAll { $0.identifier == pending.peripheralID }
            attach(restored)
        }
    }

    public func centralManager(
        _: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        if var discovery = pendingDiscovery, !discovery.finished {
            let rssi = RSSI.intValue
            if let existing = discovery.found[peripheral.identifier], existing.rssi >= rssi {
                // keep the stronger sighting
            } else {
                discovery.found[peripheral.identifier] = DiscoveredSensor(
                    peripheralID: peripheral.identifier,
                    name: advertisedName ?? peripheral.name,
                    rssi: rssi,
                    manufacturerData: manufacturerData
                )
            }
            if discovery.settle == nil {
                let settle = DispatchWorkItem { [weak self] in self?.finishDiscovery() }
                discovery.settle = settle
                queue.asyncAfter(deadline: .now() + discovery.settleWindow, execute: settle)
            }
            pendingDiscovery = discovery
            return
        }

        guard let pending = pendingConnect, !pending.finished, pending.wrapper == nil else { return }
        guard peripheral.identifier == pending.peripheralID else { return }
        logger.debug("scan matched \(peripheral.identifier.uuidString)")
        manager.stopScan()
        if let standing = pending.standing, standing !== peripheral {
            manager.cancelPeripheralConnection(standing)
            pendingConnect?.standing = nil
        }
        let wrapper = SibionicsBLEPeripheral(peripheral: peripheral, manager: manager, queue: queue)
        pendingConnect?.wrapper = wrapper
        manager.connect(peripheral, options: nil)
    }

    public func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let pending = pendingConnect, !pending.finished else { return }
        guard let wrapper = pending.wrapper, wrapper.peripheral === peripheral else { return }
        manager.stopScan()
        wrapper.beginDiscovery { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.finishPending(wrapper)
            case let .failure(error): self.failPending(error)
            }
        }
    }

    public func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let pending = pendingConnect, !pending.finished,
              pending.wrapper?.peripheral === peripheral || pending.standing === peripheral else { return }
        failPending(BLEError.connectFailed(error?.localizedDescription ?? "unknown"))
    }

    public func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        logger.info(
            "disconnected \(peripheral.identifier.uuidString)"
                + (error.map { " error=\($0.localizedDescription)" } ?? " (orderly)")
        )
        if let pending = pendingConnect, !pending.finished,
           pending.wrapper?.peripheral === peripheral || pending.standing === peripheral
        {
            failPending(BLEError.disconnected(error?.localizedDescription ?? "peer closed"))
        } else if live?.peripheral === peripheral {
            live?.handleDisconnect()
            live = nil
        }
    }
}
