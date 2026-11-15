import Foundation

/// What the driver knows about a sensor before it has spoken to it much: the
/// MAC (needed for the cipher IV), the generation, and the wear durations used
/// for warmup/expiry gating.
public struct SibionicsDeviceInfo: Equatable, Sendable, Identifiable, RawRepresentable {
    public typealias RawValue = [String: Any]

    public let mac: String
    public let model: String?
    public let serial: String?
    public let softwareRevision: String
    public let protocolGeneration: SibionicsProtocolVersion.Generation
    public let region: SibionicsProtocolVersion.Region

    /// Warmup gate: **60 minutes**. Only suppresses forwarding, never the
    /// sensor's own state, so it costs readings rather than safety if wrong.
    public let warmup: TimeInterval
    /// Wear time: **14 days**.
    public let activeDuration: TimeInterval

    public var id: String { mac }

    public init(
        mac: String,
        model: String? = nil,
        serial: String? = nil,
        softwareRevision: String,
        protocolGeneration: SibionicsProtocolVersion.Generation,
        region: SibionicsProtocolVersion.Region,
        warmup: TimeInterval = SibionicsDeviceInfo.defaultWarmup,
        activeDuration: TimeInterval = SibionicsDeviceInfo.defaultActiveDuration
    ) {
        self.mac = mac
        self.model = model
        self.serial = serial
        self.softwareRevision = softwareRevision
        self.protocolGeneration = protocolGeneration
        self.region = region
        self.warmup = warmup
        self.activeDuration = activeDuration
    }

    public static let defaultWarmup: TimeInterval = 60 * 60
    public static let defaultActiveDuration: TimeInterval = 14 * 24 * 60 * 60

    public var protocolVersion: SibionicsProtocolVersion {
        SibionicsProtocolVersion(
            softwareRevision: softwareRevision,
            manufacturer: region == .global ? "GNL" : (region == .china ? "CN" : "")
        )
    }

    // MARK: - RawRepresentable

    public init?(rawValue: RawValue) {
        guard let mac = rawValue["mac"] as? String else { return nil }
        self.mac = mac
        model = rawValue["model"] as? String
        serial = rawValue["serial"] as? String
        softwareRevision = rawValue["softwareRevision"] as? String ?? ""
        protocolGeneration = (rawValue["generation"] as? String)
            .flatMap(SibionicsProtocolVersion.Generation.init(rawValue:)) ?? .v3
        region = (rawValue["region"] as? String)
            .flatMap(SibionicsProtocolVersion.Region.init(rawValue:)) ?? .unknown
        warmup = rawValue["warmup"] as? Double ?? Self.defaultWarmup
        activeDuration = rawValue["activeDuration"] as? Double ?? Self.defaultActiveDuration
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "mac": mac,
            "softwareRevision": softwareRevision,
            "generation": protocolGeneration.rawValue,
            "region": region.rawValue,
            "warmup": warmup,
            "activeDuration": activeDuration
        ]
        raw["model"] = model
        raw["serial"] = serial
        return raw
    }

    public var debugDescription: String {
        "mac=\(SibionicsRedact.mac(mac)) gen=\(protocolGeneration.rawValue) "
            + "region=\(region.rawValue) fw=\"\(softwareRevision)\""
    }
}
