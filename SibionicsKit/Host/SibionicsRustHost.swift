import CoreBluetooth
import Foundation
import Security

/// The host runtime for the Rust `cgm-sibionics` engine (OS-AID guideline 13).
///
/// It performs the engine's actions — CoreBluetooth, the Keychain, randomness,
/// timers — and feeds the results back, on one serial queue. It knows nothing
/// about the GS3 protocol: every decision is the engine's.
///
/// The host loop (guideline 04): before each batch of input, give the engine
/// the time; then drain events, take the one outstanding action, perform it,
/// complete it, repeat; when there is no action, sleep until `pollTimeout`.
public final class SibionicsRustHost: @unchecked Sendable {
    public typealias EventHandler = @Sendable (FfiEvent) -> Void

    private let engine: SibionicsEngine
    private let central: SibionicsBLECentral
    private let storage: SibionicsRustStorage
    private let queue = DispatchQueue(label: "org.loopkit.SibionicsKit.RustHost")
    private let logger = SibionicsLogger(category: "RustHost")
    private let onEvent: EventHandler
    private let onLinkLost: @Sendable () -> Void

    /// Only touched on `queue`.
    private var peripheral: SibionicsBLEPeripheral?
    private var peripheralIDs: [Data: UUID] = [:]
    private var performing = false
    private var timer: DispatchSourceTimer?
    private var notifyTask: Task<Void, Never>?

    /// - Parameters:
    ///   - variant: a `variants()` id, chosen by the registration key.
    ///   - storageKey: separates this engine's Keychain items from others.
    public init(
        variant: String,
        storageKey: String = "default",
        central: SibionicsBLECentral = .shared,
        onEvent: @escaping EventHandler,
        onLinkLost: @escaping @Sendable () -> Void = {}
    ) throws {
        engine = try SibionicsEngine(variant: variant, utcOffsetSecs: Int32(TimeZone.current.secondsFromGMT()))
        self.central = central
        storage = SibionicsRustStorage(key: storageKey)
        self.onEvent = onEvent
        self.onLinkLost = onLinkLost
        queue.async { self.pump() }
    }

    deinit {
        timer?.cancel()
        notifyTask?.cancel()
    }

    // MARK: - Addresses

    /// iOS hides a peripheral's MAC, so the host hands the engine a stable
    /// 6-byte handle for each peripheral it knows: the first six bytes of the
    /// peripheral identifier. The engine's session stores it; the host maps it
    /// back on `Connect`.
    public static func address(for peripheralID: UUID) -> Data {
        withUnsafeBytes(of: peripheralID.uuid) { Data($0.prefix(6)) }
    }

    /// Makes `peripheralID` reachable through its address.
    @discardableResult
    public func register(_ peripheralID: UUID) -> Data {
        let address = Self.address(for: peripheralID)
        queue.sync { peripheralIDs[address] = peripheralID }
        return address
    }

    // MARK: - Commands

    /// Queues a command; its outcome arrives as `FfiEvent.finished` with this id.
    public func submit(_ command: FfiCommand) throws -> UInt32 {
        try queue.sync {
            refreshClocks()
            let id = try engine.submit(command: command)
            pump()
            return id
        }
    }

    @discardableResult
    public func stop() -> UInt32 {
        queue.sync {
            let id = engine.stop()
            pump()
            return id
        }
    }

    /// Drops the BLE link; the engine sees a link loss.
    public func disconnect() {
        queue.async {
            self.peripheral?.disconnect()
        }
    }

    /// Feeds the clocks (and any due timer) without other input, e.g. from a
    /// periodic ticker, so time-based state (warm-up, signal loss) moves.
    public func tick() {
        queue.async { self.pump() }
    }

    // MARK: - Host loop

    private static func monotonicMillis() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func refreshClocks() {
        engine.handleTimeout(nowMs: Self.monotonicMillis())
        engine.handleWallClock(nowMs: UInt64(Date().timeIntervalSince1970 * 1000))
    }

    /// On `queue`.
    private func pump() {
        refreshClocks()
        while true {
            while let event = engine.pollEvent() { onEvent(event) }
            // E1: one action at a time; the engine issues the next one only
            // after this one is completed.
            guard !performing, let action = engine.pollAction() else { break }
            performing = true
            perform(action)
        }
        scheduleTimer()
    }

    private func complete(_ id: UInt32, _ completion: FfiCompletion) {
        queue.async {
            self.performing = false
            if let note = Self.describeFailure(completion) {
                self.logger.debug("action \(id) completed: \(note)")
            }
            do {
                try self.engine.handleCompletion(id: id, completion: completion)
            } catch {
                self.logger.error("engine rejected completion \(id): \(error)")
            }
            self.pump()
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        guard let deadline = engine.pollTimeout() else { return }
        let now = Self.monotonicMillis()
        let delay = deadline > now ? deadline - now : 0
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .milliseconds(Int(min(delay, UInt64(Int32.max)))))
        source.setEventHandler { [weak self] in self?.pump() }
        source.resume()
        timer = source
    }

    // MARK: - Actions

    private func perform(_ action: FfiAction) {
        logger.debug("action \(Self.describe(action))")
        switch action {
        case let .ble(id, op):
            performBle(id, op)
        case let .store(id, slot, _, bytes):
            let ok = storage.save(bytes, slot: slot)
            complete(id, ok ? .stored : .failed)
        case let .load(id, slot):
            complete(id, .loaded(bytes: storage.load(slot: slot)))
        case let .erase(id, slot):
            storage.delete(slot: slot)
            complete(id, .stored)
        case let .wrap(id, plaintext):
            // Storage is already the Keychain (`Class.secret`): no extra wrap.
            complete(id, .wrapped(bytes: plaintext))
        case let .unwrap(id, wrapped):
            complete(id, .secret(bytes: wrapped))
        case let .random(id, len):
            var bytes = Data(count: Int(len))
            let status = bytes.withUnsafeMutableBytes {
                SecRandomCopyBytes(kSecRandomDefault, Int(len), $0.baseAddress!)
            }
            complete(id, status == errSecSuccess ? .secret(bytes: bytes) : .failed)
        case let .keyAgree(id, _, _):
            complete(id, .failed)
        }
    }

    private static func cbuuid(_ bytes: Data) -> CBUUID {
        // SIG-base UUIDs in their 16-bit form, so they compare equal to what
        // CoreBluetooth discovered.
        let base = Data([0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0x80, 0x5F, 0x9B, 0x34, 0xFB])
        if bytes.count == 16, bytes.prefix(2) == Data([0, 0]), bytes.suffix(12) == base {
            return CBUUID(data: bytes.subdata(in: 2 ..< 4))
        }
        return CBUUID(data: bytes)
    }

    private static func result(_ error: Error) -> FfiBleResult {
        switch error as? SibionicsBLEPeripheral.PeripheralError {
        case .timeout?: return .timeout
        case .disconnected?: return .disconnected
        case .characteristicNotFound?, .readFailed?: return .status(code: 0x0A)
        default: return .failed
        }
    }

    private func performBle(_ id: UInt32, _ op: FfiBleOp) {
        let peripheral = self.peripheral
        switch op {
        case let .connect(address):
            guard let peripheralID = peripheralIDs[address] else {
                logger.error("connect: unknown address")
                return complete(id, .ble(result: .failed))
            }
            Task {
                do {
                    let connected = try await self.central.connect(peripheralID: peripheralID)
                    self.queue.async {
                        self.peripheral = connected
                        self.complete(id, .ble(result: .done))
                    }
                } catch {
                    self.logger.debug("connect failed: \(error)")
                    self.complete(id, .ble(result: .disconnected))
                }
            }
        case .disconnect:
            notifyTask?.cancel()
            notifyTask = nil
            peripheral?.disconnect()
            self.peripheral = nil
            complete(id, .ble(result: .done))
        case let .read(_, characteristic):
            guard let peripheral else { return complete(id, .ble(result: .disconnected)) }
            Task {
                do {
                    let data = try await peripheral.read(Self.cbuuid(characteristic))
                    self.complete(id, .ble(result: .data(bytes: data)))
                } catch {
                    self.complete(id, .ble(result: Self.result(error)))
                }
            }
        case let .write(_, characteristic, data):
            guard let peripheral else { return complete(id, .ble(result: .disconnected)) }
            Task {
                do {
                    try await peripheral.write(data, to: Self.cbuuid(characteristic), withResponse: true)
                    self.complete(id, .ble(result: .done))
                } catch {
                    self.complete(id, .ble(result: Self.result(error)))
                }
            }
        case let .subscribe(service, characteristic, _):
            guard let peripheral else { return complete(id, .ble(result: .disconnected)) }
            Task {
                do {
                    // Returns once the CCCD write is acknowledged.
                    let stream = try await peripheral.subscribe(Self.cbuuid(characteristic))
                    self.queue.async {
                        self.listen(stream, service: service, characteristic: characteristic, on: peripheral)
                        self.complete(id, .ble(result: .done))
                    }
                } catch {
                    self.complete(id, .ble(result: Self.result(error)))
                }
            }
        case .unsubscribe:
            notifyTask?.cancel()
            notifyTask = nil
            complete(id, .ble(result: .done))
        case .requestFastInterval:
            complete(id, .ble(result: .done))
        }
    }

    // MARK: - Diagnostics

    /// An action without its payload: writes carry the auth frame and stores
    /// carry the session (account id), so only sizes are logged.
    static func describe(_ action: FfiAction) -> String {
        switch action {
        case let .ble(id, op):
            switch op {
            case .connect: return "\(id) ble connect"
            case .disconnect: return "\(id) ble disconnect"
            case let .read(_, c): return "\(id) ble read \(cbuuid(c).uuidString)"
            case let .write(_, c, data): return "\(id) ble write \(cbuuid(c).uuidString) \(data.count) B"
            case let .subscribe(_, c, _): return "\(id) ble subscribe \(cbuuid(c).uuidString)"
            case let .unsubscribe(_, c): return "\(id) ble unsubscribe \(cbuuid(c).uuidString)"
            case .requestFastInterval: return "\(id) ble fast interval"
            }
        case let .store(id, slot, _, bytes): return "\(id) store \(SibionicsRustStorage.account(slot)) \(bytes.count) B"
        case let .load(id, slot): return "\(id) load \(SibionicsRustStorage.account(slot))"
        case let .erase(id, slot): return "\(id) erase \(SibionicsRustStorage.account(slot))"
        case let .wrap(id, _): return "\(id) wrap"
        case let .unwrap(id, _): return "\(id) unwrap"
        case let .random(id, len): return "\(id) random \(len) B"
        case let .keyAgree(id, _, _): return "\(id) key agreement (unsupported)"
        }
    }

    /// `nil` for the expected completions, so the log stays readable.
    static func describeFailure(_ completion: FfiCompletion) -> String? {
        switch completion {
        case .ble(.done), .ble(.data), .stored, .wrapped, .secret: return nil
        case let .loaded(bytes): return bytes == nil ? "nothing stored" : nil
        case let .ble(result): return "ble \(result)"
        case .failed: return "failed"
        }
    }

    /// Forwards notifications; the end of the stream is a link loss.
    private func listen(
        _ stream: AsyncStream<Data>,
        service: Data,
        characteristic: Data,
        on peripheral: SibionicsBLEPeripheral
    ) {
        notifyTask?.cancel()
        notifyTask = Task { [weak self] in
            for await data in stream {
                guard let self else { return }
                self.queue.async {
                    self.refreshClocks()
                    self.engine.handleNotification(service: service, characteristic: characteristic, data: data)
                    self.pump()
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.queue.async {
                guard self.peripheral === peripheral else { return }
                self.logger.debug("notify stream ended: link lost")
                self.peripheral = nil
                self.engine.handleLinkLost()
                self.pump()
                // Reconnect policy is the host's (Open: Q2).
                self.onLinkLost()
            }
        }
    }
}

/// `Slot`s in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`,
/// as `SibionicsKeychain`). The session holds the account id (S10).
struct SibionicsRustStorage {
    private let service: String

    init(key: String) {
        service = "org.loopkit.SibionicsKit.rust.\(key)"
    }

    static func account(_ slot: FfiSlot) -> String {
        switch slot {
        case .session: return "session"
        case .pendingSession: return "pendingSession"
        case .counters: return "counters"
        case .nonceState: return "nonceState"
        case let .driver(n): return "driver\(n)"
        }
    }

    private func query(_ slot: FfiSlot) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account(slot)
        ]
    }

    func save(_ bytes: Data, slot: FfiSlot) -> Bool {
        SecItemDelete(query(slot) as CFDictionary)
        var attributes = query(slot)
        attributes[kSecValueData as String] = bytes
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    func load(slot: FfiSlot) -> Data? {
        var q = query(slot)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    func delete(slot: FfiSlot) {
        SecItemDelete(query(slot) as CFDictionary)
    }
}
