import Foundation

/// The comma-separated record on a Sibionics applicator tag.
///
/// A real GS3 tag reads:
///
///     GJ,04ES126090500NA,6,10943L
///
/// i.e. an app prefix, the **product serial**, a single-digit code, and a lot
/// number. That is not the shape the earlier notes guessed at (which had a
/// region and a MAC), so the fields are identified by shape rather than by
/// position, and the MAC is treated as optional: it is present on some tag
/// variants and absent on this one.
///
/// The serial is the useful part. It is the same string the sensor reports from
/// `F0 0E`, so a tag read before pairing can be checked against the sensor
/// actually attached afterwards — see `SibionicsPairingService.attach`.
/// A tag cannot supply the MAC for a GS3, because it does not contain one.
public struct SibionicsNFCRecord: Equatable, Sendable {
    public let raw: String
    public let fields: [String]

    /// Leading app/product marker, e.g. `GJ`.
    public let appPrefix: String?
    /// Product serial, e.g. `04ES126090500NA`. Matches the sensor's `F0 0E`.
    public let serial: String?
    /// Only on tag variants that carry one; a GS3 tag does not.
    public let mac: String?
    /// `GNL` / `CN` where a variant encodes it.
    public let regionCode: String?
    /// A `GS3…` model string where a variant carries one.
    public let model: String?
    /// Trailing six characters of a `GS3…` model, the expected BLE name suffix.
    public let bleNameSuffix: String?

    public init?(raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(",") else { return nil }
        let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2 else { return nil }

        self.raw = trimmed
        self.fields = fields

        let prefix = fields.first.map { $0.uppercased() }
        appPrefix = prefix.flatMap { value in
            (value.count == 2 && value.allSatisfy { $0.isLetter }) ? value : nil
        }

        mac = fields.compactMap(Self.macCandidate(from:)).first

        regionCode = fields.first { ["GNL", "CN"].contains($0.uppercased()) }

        model = fields.first { $0.uppercased().hasPrefix("GS3") }

        // The serial is the longest remaining field that looks like one: letters
        // and digits, at least eight characters. That picks `04ES126090500NA`
        // and skips the single-digit code and the short lot number.
        let consumed = Set([appPrefix, mac?.filter(\.isHexDigit), regionCode, model].compactMap { $0 })
        serial = fields
            .filter { field in
                guard field.count >= 8,
                      field.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
                guard !consumed.contains(field.uppercased()), !consumed.contains(field) else { return false }
                return true
            }
            .max { $0.count < $1.count }

        if let model, model.count >= 6, Self.macCandidate(from: model) == nil {
            bleNameSuffix = String(model.suffix(6)).uppercased()
        } else {
            bleNameSuffix = nil
        }

        // A record must yield *something* useful to be worth reporting.
        guard serial != nil || mac != nil else { return nil }
    }

    /// `AA:BB:CC:DD:EE:FF` if `field` is exactly 12 hex digits, else nil.
    static func macCandidate(from field: String) -> String? {
        let hex = field.uppercased().filter(\.isHexDigit)
        guard hex.count == 12, hex.count == field.count else { return nil }
        var parts: [String] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            parts.append(String(hex[index ..< next]))
            index = next
        }
        return parts.joined(separator: ":")
    }

    public var debugDescription: String {
        "nfc serial=\(serial ?? "nil") mac=\(SibionicsRedact.mac(mac)) model=\(model ?? "nil")"
    }
}
