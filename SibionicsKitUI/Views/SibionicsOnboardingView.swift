import SibionicsKit
import SwiftUI

struct SibionicsOnboardingView: View {
    @ObservedObject var model: SibionicsCGMState
    var onFinish: () -> Void
    var onCancel: () -> Void

    @State private var accountID: String = ""
    /// Off by default: Trio generates a random account id. On only for a
    /// sensor the official app already activated.
    @State private var useExistingAccountID = false
    @State private var candidates: [SibionicsBLECentral.DiscoveredSensor] = []
    @State private var selected: UUID?
    @State private var busy = false
    @State private var status: String?
    @State private var error: String?
    @State private var showPlacement = false
    /// The pairing form is a second stage; the landing page comes first.
    @State private var showPairing = false
    @State private var expectedSerial: String?
    @State private var tagStatus: String?

    var body: some View {
        Group {
            if showPairing {
                pairingForm
            } else {
                SibionicsOnboardingLandingView(
                    onShowPlacement: { showPlacement = true },
                    onContinue: { withAnimation { showPairing = true } }
                )
            }
        }
        .navigationTitle("Add Sibionics sensor")
        .toolbar {
            // Cancel leaves onboarding from the landing page; the pairing stage
            // goes back to the landing page instead.
            if !showPairing {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel", action: onCancel)
                }
            } else {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation { showPairing = false }
                    } label: {
                        Image(systemName: "chevron.backward")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .sheet(isPresented: $showPlacement) {
            SibionicsSensorPlacementView()
        }
        .onAppear {
            accountID = model.accountID ?? ""
        }
    }

    private var pairingForm: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    Image(imageName: "sensor")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 150)
                        .accessibilityHidden(true)
                    Spacer()
                }
            }

            Section {
                Toggle("Use an existing account ID", isOn: $useExistingAccountID.animation())
                if useExistingAccountID {
                    TextField("Account ID", text: $accountID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numberPad)
                        .font(.system(.body, design: .monospaced))
                }
            } header: {
                Text("Account ID")
            } footer: {
                Text(
                    useExistingAccountID
                        ?
                        "Only enter an account ID if you know what it is and where to find it. A sensor the official app already activated will only answer that app's account ID."
                        :
                        "Trio generates a random account ID for this sensor. Only turn this on if you know your account ID and where to find it."
                )
            }

            if let status {
                Section { Text(status).font(.footnote).foregroundStyle(.secondary) }
            }
            if let error {
                Section { Text(error).font(.footnote).foregroundStyle(.red) }
            }
        }
        .safeAreaInset(edge: .bottom) { scanPrompt }
    }

    /// The normal path: tap the applicator tag and let that start pairing, the
    /// way the official app does. The Bluetooth list above stays for when NFC is
    /// unavailable or the tag cannot be read.
    private var scanPrompt: some View {
        VStack(spacing: 8) {
            Button {
                Task { await scanTagAndPair() }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(.white) }
                    Image(systemName: "wave.3.right")
                    Text("Scan sensor")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.accentColor.opacity(SibionicsNFCReader.isAvailable && !busy ? 1 : 0.4))
                )
                .foregroundColor(.white)
                .font(.headline)
            }
            .buttonStyle(.plain)
            .disabled(!SibionicsNFCReader.isAvailable || busy)
        }
        .padding(.horizontal)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// The official app's flow: read the applicator tag, use it to identify the
    /// sensor, then verify the sensor that answers is the one on the tag.
    private func scanTagAndPair() async {
        busy = true
        error = nil
        status = "Hold the top of your iPhone near the sensor's tag…"
        do {
            let dump = try await SibionicsNFCReader().read()
            guard let record = dump.bestRecord, let serial = record.serial else {
                error = "That tag has no product serial this driver recognises."
                status = nil
                busy = false
                return
            }
            expectedSerial = serial
            tagStatus = "Tag serial \(serial)"
            status = "Looking for \(serial)…"

            if candidates.isEmpty { await scan() }
            if candidates.count == 1, let only = candidates.first {
                selected = only.peripheralID
                await pair()
                busy = false
                return
            }
            status = candidates.isEmpty
                ? "Tag read, but no sensor is advertising. Move closer and scan again."
                : "Tag read, but more than one sensor is advertising. Move closer to yours and scan again."
        } catch let caught {
            // `error` here is the @State property; the caught value shadows it.
            error = caught is SibionicsNFCReader.ReaderError
                ? String(describing: caught)
                : caught.localizedDescription
            status = nil
        }
        busy = false
    }

    private func scan() async {
        busy = true
        error = nil
        status = "Scanning…"
        do {
            candidates = try await model.discover()
            status = candidates.isEmpty
                ? "No sensors advertising. Move closer and try again."
                : "Found \(candidates.count) sensor(s)."
            if selected == nil { selected = candidates.first?.peripheralID }
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
        busy = false
    }

    private func pair() async {
        guard let selected else { return }
        busy = true
        error = nil
        do {
            // With the toggle off the driver generates one; a value is only
            // supplied for a sensor the official app activated.
            if useExistingAccountID, !accountID.isEmpty {
                try model.setAccountID(accountID)
            }
            try await model.pair(
                peripheralID: selected,
                mac: nil,
                expectedSerial: expectedSerial
            ) { stage in
                Task { @MainActor in
                    status = Self.describe(stage)
                }
            }
            onFinish()
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }

    static func describe(_ stage: SibionicsPairingService.Stage) -> String {
        switch stage {
        case .discovering: return "Looking for the sensor…"
        case .connecting: return "Connecting…"
        case .readingDeviceInfo: return "Reading device information…"
        case .authenticating: return "Authenticating…"
        case .activating: return "Activating…"
        case .confirmingActivation: return "Confirming activation…"
        case .startingSession: return "Starting session…"
        }
    }
}
