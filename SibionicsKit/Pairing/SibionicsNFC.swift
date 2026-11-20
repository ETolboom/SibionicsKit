import Foundation

/// The comma-separated record on a Sibionics applicator tag, e.g.
/// `GJ,04ES126090500NA,6,10943L`. Parsed by the Rust driver
/// (`cgm_sibionics::protocol::NfcRecord`); this is its Swift face.
///
/// The serial is the useful part: it is what the sensor reports from `F0 0E`,
/// so `Pair` checks it against the sensor in range.
public struct SibionicsNFCRecord: Equatable, Sendable {
    public let raw: String
    public let fields: [String]
    public let appPrefix: String?
    public let serial: String?
    public let mac: String?
    public let regionCode: String?
    public let model: String?
    public let bleNameSuffix: String?

    public init?(raw: String) {
        guard let parsed = parseNfc(text: raw) else { return nil }
        self.raw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        fields = parsed.fields
        appPrefix = parsed.appPrefix
        serial = parsed.serial
        mac = parsed.mac
        regionCode = parsed.region
        model = parsed.model
        bleNameSuffix = parsed.bleNameSuffix
    }

    public var debugDescription: String {
        "nfc serial=\(serial ?? "nil") mac=\(SibionicsRedact.mac(mac)) model=\(model ?? "nil")"
    }
}
