import Foundation

public enum SibionicsDiagnostics {
    private static let verboseKey = "SibionicsDiagnostics.verboseBLELogging"

    /// Opt-in raw ciphertext/plaintext logging. Off by default: decoded records
    /// are logged regardless, and the auth frame contains the account id.
    public static var verboseBLELogging: Bool {
        get { UserDefaults.standard.object(forKey: verboseKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: verboseKey) }
    }

    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    public static func compactHex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public enum SibionicsRedact {
    /// Keeps the last two bytes: enough to tell sensors apart in a log.
    public static func mac(_ mac: String?) -> String {
        guard let mac, !mac.isEmpty else { return "nil" }
        let hex = mac.filter(\.isHexDigit)
        guard hex.count > 4 else { return "…" }
        return "…" + hex.suffix(4).uppercased()
    }

    public static func account(_ id: String?) -> String {
        guard let id, !id.isEmpty else { return "nil" }
        return "<account \(id.count) chars>"
    }
}
