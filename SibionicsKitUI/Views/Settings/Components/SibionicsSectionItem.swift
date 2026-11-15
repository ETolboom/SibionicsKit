import SwiftUI

/// Title on the left, value in secondary text on the right — the row style the
/// sibling kits use throughout their settings screens.
struct SibionicsSectionItem: View {
    var title: Text
    var value: String
    var font: Font = .body

    var body: some View {
        HStack {
            title.foregroundColor(.primary)
            Spacer()
            Text(value).font(font).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
