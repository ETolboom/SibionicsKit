import LoopKit
import LoopKitUI
import SibionicsKit
import SwiftUI

/// Laid out like DexKit's settings screen: sensor artwork and a lifecycle
/// summary, a status card saying whether the sensor is OK, then sensor
/// information and the settings. There is deliberately no glucose list here —
/// the home page already shows the readings.
///
/// Split into one `@ViewBuilder` per section — as a single expression the body
/// exceeds what SwiftUI's inference will type-check in reasonable time.
struct SibionicsSettingsView: View {
    @Environment(\.guidanceColors) private var guidanceColors

    @ObservedObject var model: SibionicsCGMState
    var debugEnabled = false
    /// Pushing is done by `SibionicsUIController`, which owns the navigation bar.
    var onShowAccountID: (() -> Void)?
    var onShowPreviousSensor: (() -> Void)?

    @State private var pendingAction: ManagementAction?
    @State private var shareURLs: [URL] = []
    @State private var showNFCDump = false

    var body: some View {
        List {
            sensorStatusSection
            sensorInformationSection
            if model.previousSensor != nil { previousSensorSection }
            accountSection
            if debugEnabled { registrationKeySection }
            if debugEnabled { debugSection }
            managementSection
            deleteSection
        }
        .listStyle(InsetGroupedListStyle())
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            switch action {
            case .endSensor:
                Button("End Sensor", role: .destructive) { model.endSensor() }
            case .deleteCGM:
                Button("Delete CGM", role: .destructive) { model.deleteCGM() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
        .sheet(isPresented: Binding(get: { !shareURLs.isEmpty }, set: { if !$0 { shareURLs = [] } })) {
            SibionicsShareSheet(items: shareURLs)
        }
        .sheet(isPresented: $showNFCDump) {
            SibionicsNFCDebugView()
        }
    }

    // MARK: - Sensor status

    @ViewBuilder private var sensorStatusSection: some View {
        Section {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Image(imageName: "sensor")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 150)
                        .accessibilityHidden(true)
                    Spacer()
                }
                lifecycleRow.padding(.bottom, 8)
            }

            statusSummary
        }
    }

    @ViewBuilder private var lifecycleRow: some View {
        switch model.lifecycle {
        case .noSensor:
            HStack {
                Text("No sensor session running.").foregroundColor(.secondary)
                Spacer()
            }

        case let .warmup(progress, remaining):
            HStack(alignment: .lastTextBaseline) {
                Text("Warming up:").foregroundColor(.secondary)
                Spacer()
                Text("\(Int((remaining / 60).rounded(.up)))")
                    .font(.system(size: 28)).fontWeight(.heavy)
                Text("min remaining").foregroundColor(.secondary)
            }
            ProgressView(value: min(max(progress, 0), 1))
                .scaleEffect(x: 1, y: 4, anchor: .center).padding(.top, 7)

        case let .active(remaining, total):
            HStack(alignment: .lastTextBaseline) {
                Text("Sensor expires in:").foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f", remaining / 86400))
                    .font(.system(size: 28)).fontWeight(.heavy)
                Text("days").foregroundColor(.secondary)
                Text(String(format: "%.0f", remaining.truncatingRemainder(dividingBy: 86400) / 3600))
                    .font(.system(size: 28)).fontWeight(.heavy)
                Text("hrs").foregroundColor(.secondary)
            }
            ProgressView(value: min(max(1 - remaining / max(total, 1), 0), 1))
                .scaleEffect(x: 1, y: 4, anchor: .center).padding(.top, 7)
                .tint(remaining < 86400 ? guidanceColors.warning : .accentColor)

        case .expired:
            HStack {
                Text("Sensor expired!").foregroundColor(guidanceColors.critical)
                Spacer()
            }
            ProgressView(value: 1)
                .scaleEffect(x: 1, y: 4, anchor: .center).padding(.top, 7)
                .tint(guidanceColors.critical)

        case .signalLost:
            HStack {
                Text("Waiting for the sensor…").foregroundColor(.secondary)
                Spacer()
            }

        case .failed:
            HStack {
                Text("The sensor reported a problem.").foregroundColor(guidanceColors.critical)
                Spacer()
            }
        }
    }

    @ViewBuilder private var statusSummary: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle).fontWeight(.heavy).foregroundStyle(.primary)
                Text(statusMessage).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// Shown in place of the lifecycle summary, as the home screen's
    /// "Communication Error" does; a failed or expired sensor still wins.
    private var communicationError: String? {
        switch model.lifecycle {
        case .noSensor, .failed, .expired: return nil
        case .warmup, .active, .signalLost: return model.communicationError
        }
    }

    private var statusTitle: String {
        if communicationError != nil { return "Communication Error" }
        return switch model.lifecycle {
        case .noSensor: "No Sensor"
        case .warmup: "Warming Up"
        case .active: "Sensor OK"
        case .expired: "Sensor Expired"
        case .signalLost: "Signal Loss"
        case .failed: "Sensor Problem"
        }
    }

    private var statusMessage: String {
        if let communicationError { return communicationError }
        switch model.lifecycle {
        case .noSensor:
            return "Pair a sensor to start reading."
        case .warmup:
            return "The sensor is warming up; readings start automatically."
        case .active:
            return "Your sensor is functioning normally."
        case .expired:
            return "Your sensor has expired. Start a new one as soon as possible."
        case .signalLost:
            return model.isReconnecting
                ? "Reconnecting…"
                : "No readings recently. Keep the sensor in range."
        case .failed:
            return "The sensor reported a problem and needs replacing."
        }
    }

    private var statusIcon: String {
        if communicationError != nil { return "exclamationmark.circle.fill" }
        switch model.lifecycle {
        case .noSensor: return "sensor.fill"
        case .warmup: return "clock"
        case .active: return "checkmark.circle.fill"
        case .expired,
             .failed: return "exclamationmark.circle.fill"
        case .signalLost: return "antenna.radiowaves.left.and.right"
        }
    }

    private var statusColor: Color {
        if communicationError != nil { return guidanceColors.critical }
        switch model.lifecycle {
        case .active: return .green
        case .expired,
             .failed: return guidanceColors.critical
        case .signalLost: return guidanceColors.warning
        default: return .secondary
        }
    }

    // MARK: - Recent glucose

    // MARK: - Sensor information

    @ViewBuilder private var sensorInformationSection: some View {
        Section {
            // The sensor ID is shown in full: it identifies the sensor, and it
            // is printed on the packaging anyway. It is not the account id.
            SibionicsSensorIdentityRows(
                model: model.sensorModel,
                sensorID: model.mac,
                serial: model.sensorSerial,
                firmware: model.sensorFirmware
            )
            SibionicsSectionItem(
                title: Text("Started at"),
                value: model.activatedAt.map { Self.dateTime.string(from: $0) } ?? "-"
            )
            SibionicsSectionItem(
                title: Text("Ends at"),
                value: model.expirationDate.map { Self.dateTime.string(from: $0) } ?? "-"
            )
        } header: {
            Text("Sensor")
        }
    }

    /// Unheaded, as in G7SensorKit: the sensor before this one, a page apart.
    @ViewBuilder private var previousSensorSection: some View {
        Section {
            Button(action: { onShowPreviousSensor?() }) {
                HStack {
                    Text("Previous Sensor").foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Settings

    @ViewBuilder private var accountSection: some View {
        Section {
            Button(action: { onShowAccountID?() }) {
                HStack {
                    Text("Account ID").foregroundColor(.primary)
                    Spacer()
                    // Shown in full: it is the user's own id, and checking it
                    // against the one the sensor was activated with is the whole
                    // point of the row. It stays out of the shared logs, where
                    // `SibionicsRedact.account` still reduces it.
                    Text(model.accountID ?? "Not set")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Account")
        }
    }

    @ViewBuilder private var registrationKeySection: some View {
        Section("Registration key") {
            Picker("Key", selection: Binding(
                get: { model.registrationKey },
                set: { model.setRegistrationKey($0) }
            )) {
                ForEach(SibionicsRegistrationKey.known) { entry in
                    Text(entry.verified ? "\(entry.label) ✓" : entry.label).tag(entry.key)
                }
            }
            Text(
                "A per-app constant, not per-sensor. Change it only if the account id is right and auth is still refused — that makes the key the next suspect."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// Debug-only: the NFC reader and the raw-transport switch are both
    /// diagnostic tools, so they live together and away from the everyday rows.
    @ViewBuilder private var debugSection: some View {
        Section("Debug") {
            Button {
                showNFCDump = true
            } label: {
                Label("Read NFC tag and dump it", systemImage: "wave.3.right")
            }
            .disabled(!SibionicsNFCReader.isAvailable)

            Toggle("Verbose BLE logging", isOn: Binding(
                get: { SibionicsDiagnostics.verboseBLELogging },
                set: { SibionicsDiagnostics.verboseBLELogging = $0 }
            ))
            Text(
                "Reads the applicator tag and shows its raw NDEF payloads; verbose logging records every GATT write and notify, including ciphertext. Both are for a bug report or a capture you are about to decode."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// Laid out like DexKit's Manage section: share the logs, then end the
    /// sensor. Ending is destructive-looking but not destructive to the app.
    @ViewBuilder private var managementSection: some View {
        Section {
            Button(role: .destructive) {
                pendingAction = .endSensor
            } label: {
                Text("End Sensor").foregroundColor(guidanceColors.critical)
            }
            .disabled(model.mac == nil)

            Button("Share Sibionics logs") {
                shareURLs = model.logFiles()
            }
            .disabled(model.logFiles().isEmpty)
        } header: {
            Text("Manage")
        }
    }

    /// Headerless, at the very bottom, like DexKit: removing the CGM entirely is
    /// a step apart from managing a sensor.
    @ViewBuilder private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                pendingAction = .deleteCGM
            } label: {
                Text("Delete CGM").foregroundColor(guidanceColors.critical)
            }
        }
    }

    // MARK: - Management

    /// One dialog for both destructive actions: two `confirmationDialog`s on the
    /// same list fight over presentation.
    private enum ManagementAction: Int, Identifiable {
        case endSensor
        case deleteCGM

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .endSensor: return String(localized: "End this sensor?")
            case .deleteCGM: return String(localized: "Delete this CGM?")
            }
        }

        var message: String {
            switch self {
            case .endSensor:
                return String(
                    localized: "This stops reading and forgets the pairing. It does not deactivate the sensor; the sensor's own wear continues."
                )
            case .deleteCGM:
                return String(
                    localized: "Removes the Sibionics CGM from Trio entirely, including the saved sensor. You will need to pair again to use it."
                )
            }
        }
    }

    // MARK: - Helpers

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
