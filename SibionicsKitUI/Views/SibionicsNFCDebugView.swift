import SibionicsKit
import SwiftUI
import UIKit

/// Reads a Sibionics applicator tag and shows everything on it, verbatim.
///
/// This exists because the field layout of that tag is a guess: the parser picks
/// the MAC out of whichever field is 12 hex digits. A raw dump is the only way
/// to check the guess, and the text is written to be pasted into a bug report
/// unedited.
struct SibionicsNFCDebugView: View {
    /// Called when the user chooses to use a MAC the tag gave up.
    var onUseMAC: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var dump: SibionicsNFCDump?
    @State private var status: String?
    @State private var errorText: String?
    @State private var busy = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !SibionicsNFCReader.isAvailable {
                        Text("NFC reading is not available on this device (or this is a simulator).")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await scan() }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().padding(.trailing, 6) }
                            Text(dump == nil ? "Scan tag" : "Scan again")
                            Spacer()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !SibionicsNFCReader.isAvailable)

                    if let status {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let errorText {
                        Text(errorText).font(.footnote).foregroundStyle(.red)
                    }

                    if let dump {
                        Text(dump.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        HStack(spacing: 12) {
                            Button(copied ? "Copied" : "Copy dump") {
                                UIPasteboard.general.string = dump.text
                                copied = true
                            }
                            .buttonStyle(.bordered)

                            ShareLink(item: dump.text) {
                                Text("Share")
                            }
                            .buttonStyle(.bordered)
                        }

                        if let mac = dump.parsedMAC, let onUseMAC {
                            Button("Use \(mac) for pairing") {
                                onUseMAC(mac)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        } else if let mac = dump.parsedMAC {
                            Text("A MAC was found on the tag: \(mac)")
                                .font(.footnote)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("NFC tag dump")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            if dump == nil, SibionicsNFCReader.isAvailable {
                Task { await scan() }
            }
        }
    }

    private func scan() async {
        busy = true
        errorText = nil
        status = "Hold the top of your iPhone near the sensor's tag…"
        do {
            let reader = SibionicsNFCReader()
            let result = try await reader.read()
            dump = result
            status = result.records.isEmpty
                ? "Tag read, but the payload is not the expected comma-separated record."
                : "Tag read."
        } catch {
            errorText = error is SibionicsNFCReader.ReaderError
                ? String(describing: error)
                : error.localizedDescription
            status = nil
        }
        busy = false
    }
}
