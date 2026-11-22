import Foundation

/// One sensor this install has paired with.
public struct SibionicsSensorRecord: Equatable, Sendable, RawRepresentable, Identifiable {
    public typealias RawValue = [String: Any]

    public var deviceInfo: SibionicsDeviceInfo
    /// iOS's stable handle for the peripheral. Persisted so a reconnect never
    /// needs to scan.
    public var peripheralID: UUID?
    /// Written by us at activation and never correctable afterwards.
    public var activatedAt: Date?
    /// Product serial (`F0 0E`), shown in settings and matched against an
    /// applicator tag when one was scanned.
    public var serial: String?
    /// The exact 16 bytes last used in the auth frame, so a future app generation
    /// with a different registration string doesn't silently break old sensors.
    public var registrationKey: Data
    /// When this app paired it. A re-pair of the same sensor keeps the first.
    public var pairedAt: Date?
    /// When it stopped being the active sensor, and why. `nil` while active,
    /// and on records saved before this was kept.
    public var endedAt: Date?
    public var endReason: EndReason?

    /// How a sensor stopped being the active one.
    public enum EndReason: String, Sendable {
        /// A different sensor was paired.
        case replaced
        /// Ended in settings before its wear was up.
        case ended
        /// The driver had marked it failed.
        case failed
        /// Ended after its wear was up.
        case sessionEnded
    }

    public var id: String { deviceInfo.mac }

    public init(
        deviceInfo: SibionicsDeviceInfo,
        peripheralID: UUID? = nil,
        activatedAt: Date? = nil,
        serial: String? = nil,
        registrationKey: Data = SibionicsRegistrationKey.default,
        pairedAt: Date? = nil
    ) {
        self.deviceInfo = deviceInfo
        self.peripheralID = peripheralID
        self.activatedAt = activatedAt
        self.serial = serial
        self.registrationKey = registrationKey
        self.pairedAt = pairedAt
    }

    public init?(rawValue: RawValue) {
        guard let infoRaw = rawValue["deviceInfo"] as? [String: Any],
              let info = SibionicsDeviceInfo(rawValue: infoRaw) else { return nil }
        deviceInfo = info
        peripheralID = (rawValue["peripheralID"] as? String).flatMap(UUID.init(uuidString:))
        activatedAt = rawValue["activatedAt"] as? Date
        serial = rawValue["serial"] as? String
        registrationKey = (rawValue["registrationKey"] as? Data) ?? SibionicsRegistrationKey.default
        pairedAt = rawValue["pairedAt"] as? Date
        endedAt = rawValue["endedAt"] as? Date
        endReason = (rawValue["endReason"] as? String).flatMap(EndReason.init(rawValue:))
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "deviceInfo": deviceInfo.rawValue,
            "registrationKey": registrationKey
        ]
        raw["peripheralID"] = peripheralID?.uuidString
        raw["activatedAt"] = activatedAt
        raw["serial"] = serial
        raw["pairedAt"] = pairedAt
        raw["endedAt"] = endedAt
        raw["endReason"] = endReason?.rawValue
        return raw
    }
}

/// The active sensor plus a short history, persisted in `CGMManagerState`.
public struct SibionicsSensorStore: Equatable, Sendable, RawRepresentable {
    public typealias RawValue = [String: Any]

    public static let historyLimit = 5

    public private(set) var active: SibionicsSensorRecord?
    public private(set) var history: [SibionicsSensorRecord] = []

    public var activeMAC: String? { active?.deviceInfo.mac }

    /// The most recent sensor that is not the active one, for the Previous
    /// Sensor page.
    public var previous: SibionicsSensorRecord? {
        history.first { $0.id != active?.id }
    }

    public init() {}

    /// Makes `record` the active sensor. A different sensor that was active is
    /// kept in the history as replaced; the same sensor paired again keeps its
    /// first pairing date.
    public mutating func adopt(_ record: SibionicsSensorRecord, at now: Date = Date()) {
        var record = record
        if let current = active, current.id != record.id {
            markEnded(current.id, reason: .replaced, at: now)
        }
        if let earlier = history.first(where: { $0.id == record.id }) {
            record.pairedAt = earlier.pairedAt ?? record.pairedAt
        }
        record.endedAt = nil
        record.endReason = nil
        active = record
        history.removeAll { $0.deviceInfo.mac == record.deviceInfo.mac }
        history.insert(record, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    public mutating func update(_ body: (inout SibionicsSensorRecord) -> Void) {
        guard var record = active else { return }
        body(&record)
        active = record
        if let index = history.firstIndex(where: { $0.deviceInfo.mac == record.deviceInfo.mac }) {
            history[index] = record
        }
    }

    /// Ends the active sensor. It stays in the history with when and why.
    public mutating func discardActive(reason: SibionicsSensorRecord.EndReason = .ended, at now: Date = Date()) {
        if let current = active { markEnded(current.id, reason: reason, at: now) }
        active = nil
    }

    private mutating func markEnded(_ id: String, reason: SibionicsSensorRecord.EndReason, at now: Date) {
        guard let index = history.firstIndex(where: { $0.id == id }), history[index].endedAt == nil else { return }
        history[index].endedAt = now
        history[index].endReason = reason
    }

    public init?(rawValue: RawValue) {
        if let rawActive = rawValue["active"] as? [String: Any] {
            active = SibionicsSensorRecord(rawValue: rawActive)
        }
        if let rawHistory = rawValue["history"] as? [[String: Any]] {
            history = rawHistory.compactMap(SibionicsSensorRecord.init(rawValue:))
        }
    }

    public var rawValue: RawValue {
        var raw: RawValue = [:]
        raw["active"] = active?.rawValue
        if !history.isEmpty { raw["history"] = history.map(\.rawValue) }
        return raw
    }
}
