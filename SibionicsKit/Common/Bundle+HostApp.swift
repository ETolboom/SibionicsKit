import Foundation

/// A token so `LocalizedString` can find this kit's bundle without depending on
/// any particular type in the module (which would create a cycle).
final class SibionicsBundleToken {}

func LocalizedString(_ key: String, tableName: String? = nil, value: String? = nil, comment: String) -> String {
    let bundle = Bundle(for: SibionicsBundleToken.self)
    if let value {
        return NSLocalizedString(key, tableName: tableName, bundle: bundle, value: value, comment: comment)
    }
    return NSLocalizedString(key, tableName: tableName, bundle: bundle, comment: comment)
}

extension Bundle {
    /// The host app's display name, for user-facing copy.
    var hostAppName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "your app"
    }
}
