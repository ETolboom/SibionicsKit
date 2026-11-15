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

    public var id: String { deviceInfo.mac }

    public init(
        deviceInfo: SibionicsDeviceInfo,
        peripheralID: UUID? = nil,
        activatedAt: Date? = nil,
        serial: String? = nil,
        registrationKey: Data = SibionicsRegistrationKey.default
    ) {
        self.deviceInfo = deviceInfo
        self.peripheralID = peripheralID
        self.activatedAt = activatedAt
        self.serial = serial
        self.registrationKey = registrationKey
    }

    public init?(rawValue: RawValue) {
        guard let infoRaw = rawValue["deviceInfo"] as? [String: Any],
              let info = SibionicsDeviceInfo(rawValue: infoRaw) else { return nil }
        deviceInfo = info
        peripheralID = (rawValue["peripheralID"] as? String).flatMap(UUID.init(uuidString:))
        activatedAt = rawValue["activatedAt"] as? Date
        serial = rawValue["serial"] as? String
        registrationKey = (rawValue["registrationKey"] as? Data) ?? SibionicsRegistrationKey.default
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "deviceInfo": deviceInfo.rawValue,
            "registrationKey": registrationKey
        ]
        raw["peripheralID"] = peripheralID?.uuidString
        raw["activatedAt"] = activatedAt
        raw["serial"] = serial
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

    public init() {}

    public mutating func adopt(_ record: SibionicsSensorRecord) {
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

    public mutating func discardActive() {
        active = nil
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
