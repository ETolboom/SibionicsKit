import Foundation

public struct CGMManagerState: RawRepresentable, Equatable {
    public typealias RawValue = [String: Any]

    public var sensors = SibionicsSensorStore()

    /// The account id string. The *encoded* 12 bytes are derived from it on
    /// demand; this is the only place the raw value is kept, and it is
    /// duplicated to the Keychain (see `SibionicsKeychain`).
    public var accountID: String?

    public var latestReadingTimestamp: Date?
    /// Newest record index actually ingested. Backfill watermark and the
    /// duplicate guard both key off it.
    public var lastIngestedSequence: UInt16?
    public var latestSample: GlucoseSample?
    public var recentSamples: [GlucoseSample] = []
    public static let recentSamplesPersistenceCap = 12

    public var sensorFault: SibionicsSensorFault.Kind?
    /// The sensor refused the account id. Kept across restarts so the app does
    /// not quietly log in with an older session; cleared when the id changes
    /// or a pairing succeeds.
    public var accountRefused = false
    public var sensorNeedsReplacement: Bool { sensorFault != nil }

    /// Warmup and wear. Assumed defaults until confirmed on hardware; the user
    /// can override them in Settings, and they only ever gate *forwarding*.
    public var warmup: TimeInterval = SibionicsDeviceInfo.defaultWarmup
    public var activeDuration: TimeInterval = SibionicsDeviceInfo.defaultActiveDuration

    /// Which registration-key constant goes into the auth frame. A per-*app*
    /// identity, not per-sensor; exposed because a sensor activated by a
    /// different Sibionics app build may expect a different one.
    public var registrationKey: Data = SibionicsRegistrationKey.default

    public var mac: String? { sensors.active?.deviceInfo.mac }
    public var peripheralID: UUID? { sensors.active?.peripheralID }
    public var activatedAt: Date? { sensors.active?.activatedAt }
    /// The key the active sensor was paired with, if any.
    public var activeRegistrationKey: Data { sensors.active?.registrationKey ?? registrationKey }

    public mutating func resetSensorSession() {
        latestReadingTimestamp = nil
        lastIngestedSequence = nil
        latestSample = nil
        recentSamples = []
        sensorFault = nil
    }

    public init() {}

    public init?(rawValue: RawValue) {
        if let sensorsRaw = rawValue["sensors"] as? [String: Any],
           let sensors = SibionicsSensorStore(rawValue: sensorsRaw)
        {
            self.sensors = sensors
        }
        accountID = rawValue["accountID"] as? String
        latestReadingTimestamp = rawValue["latestReadingTimestamp"] as? Date
        lastIngestedSequence = (rawValue["lastIngestedSequence"] as? Int).map { UInt16(clamping: $0) }
        if let latestRaw = rawValue["latestSample"] as? [String: Any] {
            latestSample = GlucoseSample(rawValue: latestRaw)
        }
        if let recentRaw = rawValue["recentSamples"] as? [[String: Any]] {
            recentSamples = recentRaw.compactMap(GlucoseSample.init(rawValue:))
        }
        if let kind = rawValue["sensorFault"] as? String, kind == "implausible" {
            sensorFault = .signalImplausible
        }
        accountRefused = rawValue["accountRefused"] as? Bool ?? false
        warmup = rawValue["warmup"] as? Double ?? SibionicsDeviceInfo.defaultWarmup
        activeDuration = rawValue["activeDuration"] as? Double ?? SibionicsDeviceInfo.defaultActiveDuration
        if let key = rawValue["registrationKey"] as? Data, key.count == 16 {
            registrationKey = key
        }
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "sensors": sensors.rawValue,
            "warmup": warmup,
            "activeDuration": activeDuration,
            "registrationKey": registrationKey
        ]
        // The raw account id is deliberately *not* written here; the Keychain
        // copy is authoritative and `rawState` is world-readable to the host.
        raw["latestReadingTimestamp"] = latestReadingTimestamp
        raw["lastIngestedSequence"] = lastIngestedSequence.map { Int($0) }
        raw["latestSample"] = latestSample?.rawValue
        if !recentSamples.isEmpty {
            raw["recentSamples"] = recentSamples.prefix(Self.recentSamplesPersistenceCap).map(\.rawValue)
        }
        if sensorFault == .signalImplausible { raw["sensorFault"] = "implausible" }
        if accountRefused { raw["accountRefused"] = true }
        return raw
    }

    public var debugDescription: String {
        [
            "* mac: \(SibionicsRedact.mac(mac))",
            "* peripheralID: \(peripheralID?.uuidString ?? "nil")",
            "* activatedAt: \(activatedAt.map { "\($0)" } ?? "nil")",
            "* lastIngestedSequence: \(lastIngestedSequence.map(String.init) ?? "nil")",
            "* latestReadingTimestamp: \(latestReadingTimestamp.map { "\($0)" } ?? "nil")",
            "* sensorFault: \(sensorFault.map { "\($0)" } ?? "nil")"
        ].joined(separator: "\n")
    }
}
