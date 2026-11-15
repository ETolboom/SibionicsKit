import SwiftUI

/// Where the account id comes from, for the sensor that was already activated by
/// the official app.
///
/// Placeholder in the sense that the menu path is not verified against the
/// current version of that app — the identifier itself is described accurately,
/// and the sheet says so rather than inventing screenshots.
struct SibionicsAccountIDHelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    advice(
                        icon: "person.text.rectangle",
                        title: String(localized: "It is your Sibionics profile id"),
                        body: String(
                            localized: "The official app shows it in your profile / account details. It is a long decimal number, usually around 19 digits."
                        )
                    )
                    advice(
                        icon: "lock.fill",
                        title: String(localized: "Only needed for an already-activated sensor"),
                        body: String(
                            localized: "The sensor remembers the account id it was activated with and will only answer that one. For a sensor you are about to activate, leave the field empty and Trio generates one."
                        )
                    )
                    advice(
                        icon: "exclamationmark.triangle",
                        title: String(localized: "A wrong id just fails to pair"),
                        body: String(
                            localized: "Authentication is refused and the sensor keeps the id it already had. Nothing is written to the sensor by trying."
                        )
                    )
                    advice(
                        icon: "questionmark.circle",
                        title: String(localized: "Not sure?"),
                        body: String(
                            localized: "If the official app did not activate this sensor, there is nothing to look up. Scan the applicator tag instead: Trio finds the sensor over Bluetooth."
                        )
                    )
                    Text(
                        "The exact place the official app shows the id differs between versions; this sheet describes what to look for rather than a fixed menu path."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
            }
            .navigationTitle("Account ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func advice(icon: String, title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(body)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
