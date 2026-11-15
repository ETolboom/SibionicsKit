import LoopKitUI
import SibionicsKit
import SwiftUI

/// The escape hatch: type in the account id a sensor was bound to.
///
/// This is all that "moving an existing sensor to Trio" needs. The auth frame
/// carries the MAC (read from the sensor), a per-app registration constant, and
/// this 12-byte value; the sensor compares the value and nothing else. Nothing
/// is written to the sensor by saving it here — the next attempt only
/// authenticates, and activation is a separate, deliberate step.
///
/// Pushed from the settings list rather than presented as a sheet, so the nav
/// bar supplies the title and the way back, and Save is a full-width button
/// pinned to the bottom. Laid out like `G7CalibrationAdviceView`: icon-and-text
/// rows on the plain background, not a `Form` of headed sections, because this
/// is mostly something to read.
struct SibionicsAccountIDEditor: View {
    @ObservedObject var model: SibionicsCGMState
    /// Called after a successful save, so the controller can pop.
    var onSaved: () -> Void

    @State private var text = ""
    @State private var errorText: String?
    @State private var loaded = false
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                inputField
                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                advice(
                    icon: "number",
                    title: String(localized: "Digits only"),
                    body: String(
                        localized: "The vendor issues account ids as decimal numbers. Anything that is not a digit is dropped as you type."
                    )
                )
                advice(
                    icon: "info.circle",
                    title: String(localized: "The id the sensor was activated with"),
                    body: String(
                        localized: "For a sensor the official app started, that is your Sibionics account id. A sensor this driver activated uses a value it generated locally."
                    )
                )
                advice(
                    icon: "lock.fill",
                    title: String(localized: "Nothing is written to the sensor"),
                    body: String(
                        localized: "Nothing can be: the account id is fixed when the sensor is activated, so the sensor keeps the one it was bound to. Changing it here only changes what Trio authenticates with."
                    )
                )
                if model.hasSensor {
                    advice(
                        icon: "arrow.triangle.2.circlepath",
                        title: String(localized: "Saving reconnects"),
                        body: String(
                            localized: "The link is re-established and the sensor is asked to authenticate again with this value. Save an empty field to forget the stored id."
                        )
                    )
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            Button(action: save) {
                Text("Save")
                    .actionButtonStyle(.primary)
            }
            .padding()
            .background(Color(.systemBackground))
        }
        // The title is set by `SibionicsUIController` on the pushed controller;
        // a `navigationTitle` here does not reach that bar.
        .toolbar {
            // iOS gives a number pad no return key, so there is no built-in way
            // to put the keyboard away. This is that way.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFieldFocused = false }
            }
        }
        .onAppear {
            // Prefill so a typo in the current value can be seen and fixed.
            guard !loaded else { return }
            loaded = true
            text = model.accountID ?? ""
        }
    }

    // MARK: - Pieces

    private var inputField: some View {
        HStack(spacing: 8) {
            TextField("2121771491330663241", text: $text)
                .keyboardType(.numberPad)
                .focused($isFieldFocused)
                .font(.system(.title3, design: .monospaced))
            // Clearing the field and saving is how the stored id is removed:
            // `setAccountID` treats an empty value as "forget it" and drops the
            // Keychain copy.
            if !text.isEmpty {
                Button {
                    text = ""
                    isFieldFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Clear account id"))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .onChange(of: text) { _, newValue in
            // Numeric only: the id the vendor issues is a decimal UInt64, and
            // this field used to accept any string, which silently took the
            // untested hashing path.
            let digits = newValue.filter(\.isNumber)
            if digits != newValue { text = digits }
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

    // MARK: - Saving

    private func save() {
        do {
            try model.setAccountID(text.trimmingCharacters(in: .whitespacesAndNewlines))
            onSaved()
        } catch {
            errorText = error is SibionicsAccountID.EncodingError
                ? String(describing: error)
                : error.localizedDescription
        }
    }
}
