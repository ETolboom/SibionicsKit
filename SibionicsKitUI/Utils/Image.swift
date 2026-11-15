import SwiftUI

/// Anchor for `Bundle(for:)` in this module. Using a dedicated token rather than
/// the view controller keeps artwork lookups independent of which types happen
/// to be in scope.
final class SibionicsUIBundleToken {}

extension Bundle {
    static var sibionicsUI: Bundle { Bundle(for: SibionicsUIBundleToken.self) }
}

extension Image {
    /// Loads artwork from this framework's own asset catalog, falling back to a
    /// system glyph so a missing asset is never a blank space.
    init(imageName: String) {
        if UIImage(named: imageName, in: .sibionicsUI, compatibleWith: nil) != nil {
            self.init(imageName, bundle: .sibionicsUI)
        } else {
            self.init(systemName: "sensor.tag.radiowaves.forward")
        }
    }
}
