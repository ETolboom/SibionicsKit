@preconcurrency import CoreBluetooth
import Foundation

/// One connected sensor. Wraps CoreBluetooth's callback soup into async
/// read/write plus an `AsyncStream` per notifying characteristic.
public final class SibionicsBLEPeripheral: NSObject, SibionicsGATTTransport, @unchecked Sendable {
    public enum PeripheralError: Error, CustomStringConvertible {
        case characteristicNotFound(CBUUID)
        case readFailed(String)
        case writeFailed(String)
        case tooLongForMTU(requested: Int, limit: Int)
        case disconnected
        case timeout

        public var description: String {
            switch self {
            case let .characteristicNotFound(u): return "characteristic \(u) not found on sensor"
            case let .readFailed(m): return "GATT read failed: \(m)"
            case let .writeFailed(m): return "GATT write failed: \(m)"
            case let .tooLongForMTU(requested, limit):
                return "frame is \(requested) bytes but this link only carries \(limit)"
            case .disconnected: return "sensor disconnected"
            case .timeout: return "GATT request timed out"
            }
        }
    }

    private static let defaultTimeout: TimeInterval = 8

    let peripheral: CBPeripheral
    public let name: String?

    private weak var manager: CBCentralManager?
    private let queue: DispatchQueue
    private let logger = SibionicsLogger(category: "BLEPeripheral")

    private var characteristics: [CBUUID: CBCharacteristic] = [:]
    private var notifyStreams: [CBUUID: [UUID: AsyncStream<Data>.Continuation]] = [:]
    private var notifyEnableWaiters: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var disconnected = false

    private struct PendingRequest<Value> {
        let id: UUID
        let continuation: CheckedContinuation<Value, Error>
        let timeoutItem: DispatchWorkItem
    }

    private var pendingReads: [CBUUID: [PendingRequest<Data>]] = [:]
    private var pendingWrites: [CBUUID: [PendingRequest<Void>]] = [:]
    private var discoveryCompletion: ((Result<Void, Error>) -> Void)?
    private var outstandingServices = 0
    private var discoveryError: Error?

    public var peripheralID: UUID { peripheral.identifier }

    init(peripheral: CBPeripheral, manager: CBCentralManager, queue: DispatchQueue) {
        self.peripheral = peripheral
        self.manager = manager
        self.queue = queue
        name = peripheral.name
        super.init()
        peripheral.delegate = self
    }

    /// Requests a larger MTU and discovers the characteristics the protocol
    /// layer needs. The vendor's write characteristic is the only one that
    /// matters for correctness; a missing device-info service is tolerated
    /// because generation detection degrades to "assume V3".
    func beginDiscovery(completion: @escaping (Result<Void, Error>) -> Void) {
        discoveryCompletion = completion
        peripheral.discoverServices(SibionicsGATT.servicesToDiscover)
    }

    /// The usable write payload. Read from CoreBluetooth rather than assumed,
    /// because a frame longer than this must fail loudly before the write.
    public var maximumWriteLength: Int { peripheral.maximumWriteValueLength(for: .withResponse) }

    private func finishDiscovery(_ result: Result<Void, Error>) {
        guard let completion = discoveryCompletion else { return }
        discoveryCompletion = nil
        completion(result)
    }

    // MARK: - SibionicsGATTTransport

    public func read(_ characteristic: CBUUID) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                guard !self.disconnected else { return cont.resume(throwing: PeripheralError.disconnected) }
                guard let characteristicObject = self.characteristics[characteristic] else {
                    return cont.resume(throwing: PeripheralError.characteristicNotFound(characteristic))
                }
                let requestID = UUID()
                let timeoutItem = DispatchWorkItem { [weak self] in
                    guard let self,
                          var list = self.pendingReads[characteristic],
                          let index = list.firstIndex(where: { $0.id == requestID }) else { return }
                    let entry = list.remove(at: index)
                    self.pendingReads[characteristic] = list
                    entry.continuation.resume(throwing: PeripheralError.timeout)
                }
                self.pendingReads[characteristic, default: []]
                    .append(PendingRequest(id: requestID, continuation: cont, timeoutItem: timeoutItem))
                self.peripheral.readValue(for: characteristicObject)
                self.queue.asyncAfter(deadline: .now() + Self.defaultTimeout, execute: timeoutItem)
            }
        }
    }

    public func write(_ data: Data, to characteristic: CBUUID, withResponse: Bool) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.disconnected else { return cont.resume(throwing: PeripheralError.disconnected) }
                guard let characteristicObject = self.characteristics[characteristic] else {
                    return cont.resume(throwing: PeripheralError.characteristicNotFound(characteristic))
                }
                if characteristic == SibionicsGATT.writeCharacteristic {
                    self.logger.debug(
                        "GATT write \(SibionicsDiagnostics.hex(data)) [\(withResponse ? "ack" : "no-ack")]"
                    )
                }
                if !withResponse {
                    self.peripheral.writeValue(data, for: characteristicObject, type: .withoutResponse)
                    cont.resume()
                    return
                }
                let limit = self.peripheral.maximumWriteValueLength(for: .withResponse)
                if data.count > limit {
                    return cont.resume(throwing: PeripheralError.tooLongForMTU(requested: data.count, limit: limit))
                }
                let requestID = UUID()
                let timeoutItem = DispatchWorkItem { [weak self] in
                    guard let self,
                          var list = self.pendingWrites[characteristic],
                          let index = list.firstIndex(where: { $0.id == requestID }) else { return }
                    let entry = list.remove(at: index)
                    self.pendingWrites[characteristic] = list
                    entry.continuation.resume(throwing: PeripheralError.timeout)
                }
                self.pendingWrites[characteristic, default: []]
                    .append(PendingRequest(id: requestID, continuation: cont, timeoutItem: timeoutItem))
                self.peripheral.writeValue(data, for: characteristicObject, type: .withResponse)
                self.queue.asyncAfter(deadline: .now() + Self.defaultTimeout, execute: timeoutItem)
            }
        }
    }

    public func subscribe(_ characteristic: CBUUID) async throws -> AsyncStream<Data> {
        let id = UUID()
        let stream = AsyncStream<Data> { continuation in
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.notifyStreams[characteristic]?.removeValue(forKey: id) }
            }
            queue.async {
                guard !self.disconnected, self.characteristics[characteristic] != nil else {
                    continuation.finish()
                    return
                }
                // Register before enabling, so a value that arrives immediately
                // after the CCCD acknowledgement still finds a consumer.
                self.notifyStreams[characteristic, default: [:]][id] = continuation
            }
        }
        try await enableNotifications(characteristic)
        return stream
    }

    /// Waits for `didUpdateNotificationStateFor` with `isNotifying == true`.
    private func enableNotifications(_ characteristic: CBUUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.disconnected else { return continuation.resume(throwing: PeripheralError.disconnected) }
                guard let characteristicObject = self.characteristics[characteristic] else {
                    return continuation.resume(throwing: PeripheralError.characteristicNotFound(characteristic))
                }
                if characteristicObject.isNotifying {
                    return continuation.resume()
                }
                self.notifyEnableWaiters[characteristic] = continuation
                self.peripheral.setNotifyValue(true, for: characteristicObject)
                self.queue.asyncAfter(deadline: .now() + Self.defaultTimeout) { [weak self] in
                    guard let self,
                          let waiter = self.notifyEnableWaiters.removeValue(forKey: characteristic) else { return }
                    waiter.resume(throwing: PeripheralError.timeout)
                }
            }
        }
    }

    public func disconnect() {
        queue.async {
            guard !self.disconnected else { return }
            self.manager?.cancelPeripheralConnection(self.peripheral)
        }
    }

    func handleDisconnect() {
        guard !disconnected else { return }
        disconnected = true
        notifyStreams.values.flatMap(\.values).forEach { $0.finish() }
        notifyStreams.removeAll()
        notifyEnableWaiters.values.forEach { $0.resume(throwing: PeripheralError.disconnected) }
        notifyEnableWaiters.removeAll()
        pendingReads.values.flatMap { $0 }.forEach { $0.continuation.resume(throwing: PeripheralError.disconnected) }
        pendingReads.removeAll()
        pendingWrites.values.flatMap { $0 }.forEach { $0.continuation.resume(throwing: PeripheralError.disconnected) }
        pendingWrites.removeAll()
        finishDiscovery(.failure(PeripheralError.disconnected))
    }
}

extension SibionicsBLEPeripheral: CBPeripheralDelegate {
    public func peripheral(_: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { return finishDiscovery(.failure(error)) }
        let services = peripheral.services ?? []
        outstandingServices = services.count
        guard outstandingServices > 0 else { return finishDiscovery(.failure(PeripheralError.disconnected)) }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    public func peripheral(_: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { discoveryError = error }
        for characteristic in service.characteristics ?? [] {
            characteristics[characteristic.uuid] = characteristic
        }
        outstandingServices -= 1
        if outstandingServices <= 0 {
            if let discoveryError { finishDiscovery(.failure(discoveryError)) }
            else { finishDiscovery(.success(())) }
        }
    }

    public func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid
        if var waiting = pendingReads[uuid], !waiting.isEmpty {
            let entry = waiting.removeFirst()
            entry.timeoutItem.cancel()
            let continuation = entry.continuation
            pendingReads[uuid] = waiting
            if let error {
                continuation.resume(throwing: PeripheralError.readFailed(error.localizedDescription))
            } else {
                let value = characteristic.value ?? Data()
                logger.debug("GATT read \(uuid.uuidString) \(value.count) B: \(SibionicsDiagnostics.hex(value))")
                continuation.resume(returning: value)
            }
            return
        }
        guard error == nil, let value = characteristic.value else { return }
        if SibionicsDiagnostics.verboseBLELogging {
            logger.debug("GATT notify \(uuid.uuidString) \(value.count) B: \(SibionicsDiagnostics.hex(value))")
        }
        notifyStreams[uuid]?.values.forEach { $0.yield(value) }
    }

    public func peripheral(
        _: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let waiter = notifyEnableWaiters.removeValue(forKey: characteristic.uuid) {
            if let error {
                waiter.resume(throwing: PeripheralError.readFailed(error.localizedDescription))
            } else {
                waiter.resume()
            }
        }
        if let error {
            logger.error(
                "notify enable failed for \(characteristic.uuid.uuidString): \(error.localizedDescription); "
                    + "ending the stream so the link recovers via reconnect"
            )
            notifyStreams[characteristic.uuid]?.values.forEach { $0.finish() }
            notifyStreams.removeValue(forKey: characteristic.uuid)
        } else {
            logger.debug("notify \(characteristic.isNotifying ? "enabled" : "disabled") \(characteristic.uuid.uuidString)")
        }
    }

    public func peripheral(_: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard var waiting = pendingWrites[characteristic.uuid], !waiting.isEmpty else { return }
        let entry = waiting.removeFirst()
        entry.timeoutItem.cancel()
        let continuation = entry.continuation
        pendingWrites[characteristic.uuid] = waiting
        if let error {
            continuation.resume(throwing: PeripheralError.writeFailed(error.localizedDescription))
        } else {
            continuation.resume()
        }
    }

    public func peripheral(
        _: CBPeripheral,
        didReadRSSI RSSI: NSNumber,
        error: Error?
    ) {
        if let error {
            logger.debug("RSSI read failed: \(error.localizedDescription)")
        } else {
            logger.debug("RSSI \(RSSI.intValue)")
        }
    }
}
