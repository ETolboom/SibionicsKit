import Foundation

/// Which wire generation a sensor speaks, derived from Device Information
/// (service `0x180A`).
///
/// * `softwareRevision` containing `_V3.` → V3 (AES-128-OFB). This is the only
///   generation implemented here.
/// * otherwise → V2 (RC4). Recognised but refused: its registration keys and
///   RC4 key are not in this codebase, and its auth/bind sequence differs.
///
/// The vendor region lives in the manufacturer string (`… GNL` global / `… CN`
/// China) and, on V3, only matters for which registration key an app ships.
public struct SibionicsProtocolVersion: Equatable, Sendable {
    public enum Generation: String, Equatable, Sendable {
        case v2
        case v3
    }

    public enum Region: String, Equatable, Sendable {
        case global
        case china
        case unknown
    }

    public let generation: Generation
    public let region: Region
    public let softwareRevision: String
    public let manufacturer: String
    public let modelNumber: String?

    public init(softwareRevision: String, manufacturer: String, modelNumber: String? = nil) {
        self.softwareRevision = softwareRevision
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber

        generation = softwareRevision.localizedCaseInsensitiveContains("_V3.") ? .v3 : .v2

        let trimmedManufacturer = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmedManufacturer.hasSuffix("GNL") {
            region = .global
        } else if trimmedManufacturer.hasSuffix("CN") {
            region = .china
        } else {
            region = .unknown
        }
    }

    public var isSupported: Bool { generation == .v3 }

    public var description: String {
        "\(generation.rawValue) region=\(region.rawValue) fw=\"\(softwareRevision)\""
    }
}

/// The static, per-app 16-byte "registration key" that goes into the V3 auth
/// frame. It is not per-sensor and not negotiated; it identifies the app
/// generation to the sensor.
///
/// **Status: needs confirming for this driver's target.** Juggluco's table
/// lists `THE544U0TYITE461` for the `gs3`/`sijoy` apps and says the V3 support
/// was verified with it on a GNL sensor, which is what is used here. For
/// reference, the official iOS app does not store it in the clear: it derives
/// it at runtime from a per-app `appKey` blob (see
/// `GS3-activation-findings.md`). If auth fails with a valid account id,
/// suspect this constant before anything else.
public enum SibionicsRegistrationKey {
    /// `sijoy` / `gs3` — the V3 value verified against a real GNL sensor.
    public static let gs3 = Data("THE544U0TYITE461".utf8)

    /// `rusibionics`. Unverified here.
    public static let russian = Data("LQSS54U0RURUA99J".utf8)

    /// `sisensingcgm` / `eco` / `gstoc`. Guessed upstream, unverified.
    public static let sensing = Data("GKSHGDU0TYA456G4".utf8)

    /// The default for a GS3 (the model this driver targets).
    public static let `default` = gs3

    /// The known constants, for a picker and for naming a key found in a
    /// capture. Only `gs3` is confirmed against hardware.
    public struct Known: Identifiable, Sendable {
        public let id: String
        public let label: String
        public let key: Data
        public let verified: Bool
    }

    public static let known: [Known] = [
        Known(id: "gs3", label: "GS3 / sijoy", key: gs3, verified: true),
        Known(id: "ru", label: "rusibionics", key: russian, verified: false),
        Known(id: "sensing", label: "siSensing / eco / gstoc", key: sensing, verified: false)
    ]

    /// Human-readable name for a key, for logs and pickers.
    public static func label(for key: Data) -> String {
        known.first { $0.key == key }.map(\.label) ?? "custom (\(key.count) B)"
    }
}
