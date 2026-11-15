import Foundation

/// Everything a Sibionics applicator tag gave up, formatted for a human and for
/// a bug report.
///
/// Deliberately has no CoreNFC dependency so it can be built and unit-tested on
/// any platform; `SibionicsNFCReader` fills it in on a device.
///
/// The point of the raw payloads being here is that the field parsing in
/// `SibionicsNFCRecord` is a guess. If the guess is wrong, this dump still shows
/// the truth, which is what makes it worth sharing.
public struct SibionicsNFCDump: Equatable, Sendable {
    public struct Payload: Equatable, Sendable {
        /// NDEF type name format, spelled out (`well-known`, `media`, `absolute-uri`, …).
        public let typeNameFormat: String
        /// The record type, made printable (`T`, `U`, `text/plain`, …).
        public let typeDescription: String
        public let identifier: Data
        public let payload: Data
        /// Best-effort decoded text: NDEF text/URI records first, then plain UTF-8.
        public let decoded: String?

        public init(
            typeNameFormat: String,
            typeDescription: String,
            identifier: Data = Data(),
            payload: Data
        ) {
            self.typeNameFormat = typeNameFormat
            self.typeDescription = typeDescription
            self.identifier = identifier
            self.payload = payload
            decoded = Self.decode(type: typeDescription, payload: payload)
        }

        /// NDEF text (`T`) and URI (`U`) records carry a prefix that has to be
        /// stripped; anything else is tried as UTF-8 so a vendor string still
        /// shows up.
        static func decode(type: String, payload: Data) -> String? {
            let bytes = [UInt8](payload)
            switch type {
            case "T":
                guard let status = bytes.first else { return nil }
                let languageLength = Int(status & 0x3F)
                let start = 1 + languageLength
                guard start <= bytes.count else { return nil }
                return String(bytes: bytes[start...], encoding: .utf8)
            case "U":
                guard let code = bytes.first else { return nil }
                let prefix = Self.uriPrefixes[min(Int(code), Self.uriPrefixes.count - 1)]
                let rest = String(bytes: bytes.dropFirst(), encoding: .utf8) ?? ""
                return prefix + rest
            default:
                guard let text = String(bytes: bytes, encoding: .utf8) else { return nil }
                // Only claim a decode when it is actually text, not binary that
                // happens to be valid UTF-8.
                let printable = text.unicodeScalars.filter {
                    CharacterSet.alphanumerics.union(.punctuationCharacters)
                        .union(.whitespaces).contains($0)
                }
                guard printable.count == text.unicodeScalars.count else { return nil }
                return text
            }
        }

        /// NDEF URI identifier codes, per the NFC Forum URI Record Type Definition.
        static let uriPrefixes = [
            "", "http://www.", "https://www.", "http://", "https://", "tel:",
            "mailto:", "ftp://anonymous:anonymous@", "ftp://ftp.", "ftps://",
            "sftp://", "smb://", "nfs://", "ftp://", "dav://", "news:",
            "telnet://", "imap:", "rtsp://", "urn:", "pop:", "sip:", "sips:",
            "tftp:", "btspp://", "btl2cap://", "btgoep://", "tcpobex://",
            "irdaobex://", "file://", "urn:epc:id:", "urn:epc:tag:",
            "urn:epc:pat:", "urn:epc:raw:", "urn:epc:", "urn:nfc:"
        ]

        public var hexDescription: String {
            payload.map { String(format: "%02x", $0) }.joined(separator: " ")
        }

        public var summary: String {
            let type = typeDescription.isEmpty ? "?" : typeDescription
            let body = decoded.map { "\"\($0)\"" } ?? "(\(payload.count) B binary)"
            return "\(typeNameFormat)/\(type) \(body)"
        }
    }

    public let tagType: String
    public let identifier: Data
    public let ndefStatus: String
    public let capacity: Int?
    public let payloads: [Payload]
    /// Concatenation of every decoded payload, in order, so a tag that splits
    /// its record across payloads still parses.
    public let records: [SibionicsNFCRecord]

    public init(
        tagType: String,
        identifier: Data = Data(),
        ndefStatus: String,
        capacity: Int? = nil,
        payloads: [Payload]
    ) {
        self.tagType = tagType
        self.identifier = identifier
        self.ndefStatus = ndefStatus
        self.capacity = capacity
        self.payloads = payloads

        var parsed: [SibionicsNFCRecord] = []
        for payload in payloads {
            if let text = payload.decoded, let record = SibionicsNFCRecord(raw: text) {
                parsed.append(record)
            }
        }
        if parsed.isEmpty {
            // Last resort: the payload may be the comma string with a prefix or
            // suffix we don't decode, so look for the shape anywhere in it.
            let joined = payloads.compactMap(\.decoded).joined(separator: "\n")
            if let record = SibionicsNFCRecord(raw: joined) {
                parsed.append(record)
            }
        }
        records = parsed
    }

    public var bestRecord: SibionicsNFCRecord? { records.first }

    /// The MAC the loader would use, if a tag variant gave one up. A GS3 tag
    /// does not: its MAC comes from the sensor's `0x2A25`.
    public var parsedMAC: String? { bestRecord?.mac }

    /// The product serial the tag names. This is the value to check against the
    /// sensor after pairing, not before.
    public var parsedSerial: String? { bestRecord?.serial }

    public var hexDescription: String {
        identifier.map { String(format: "%02x", $0) }.joined()
    }

    /// The text shown in the debug screen and copied into a bug report. Keep it
    /// stable-ish: it is meant to be pasted verbatim.
    public var text: String {
        var lines: [String] = []
        lines.append("Sibionics NFC debug dump")
        lines.append("tag:      \(tagType)")
        lines.append("uid:      \(hexDescription.isEmpty ? "(none)" : hexDescription)")
        lines.append("NDEF:     \(ndefStatus)\(capacity.map { ", capacity \($0) B" } ?? "")")
        lines.append("payloads: \(payloads.count)")
        lines.append("")

        for (index, payload) in payloads.enumerated() {
            lines.append("[\(index)] \(payload.summary)")
            if !payload.identifier.isEmpty {
                lines.append("    id:  \(payload.identifier.map { String(format: "%02x", $0) }.joined())")
            }
            lines.append("    raw: \(payload.hexDescription)")
        }

        lines.append("")
        if records.isEmpty {
            lines.append("parsed record: none — the payload is not the expected comma-separated string")
            if let first = payloads.compactMap(\.decoded).first {
                lines.append("  decoded text: \"\(first)\"")
            }
        } else {
            for record in records {
                lines.append("parsed record:")
                lines.append("  fields: \(record.fields.joined(separator: " | "))")
                lines.append("  prefix: \(record.appPrefix ?? "(none)")")
                lines.append("  serial: \(record.serial ?? "(none found)")")
                lines.append("  model:  \(record.model ?? "(none)")")
                lines.append("  region: \(record.regionCode ?? "(none)")")
                lines.append("  mac:    \(record.mac ?? "(none — a GS3 tag carries no MAC)")")
                if record.serial != nil {
                    lines.append("  serial is checked against the sensor's F0 0E reply after pairing")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}
