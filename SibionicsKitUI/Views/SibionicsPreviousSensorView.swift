import LoopKitUI
import SibionicsKit
import SwiftUI

/// The sensor before the current one: what it was, when it ran, how it ended
/// (as G7SensorKit's `G7PreviousSensorView`).
struct SibionicsPreviousSensorView: View {
    let record: SibionicsSensorRecord

    @Environment(\.guidanceColors) private var guidanceColors

    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let duration: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter
    }()

    var body: some View {
        List {
            if record.endReason == .failed {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(guidanceColors.critical)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sensor Failed").font(.headline)
                            Text("The sensor reported a problem and was replaced.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section {
                SibionicsSensorIdentityRows(
                    model: record.deviceInfo.model ?? "GS3",
                    sensorID: record.deviceInfo.mac.isEmpty ? nil : record.deviceInfo.mac,
                    serial: record.serial ?? record.deviceInfo.serial,
                    firmware: record.deviceInfo.softwareRevision
                )
            } header: {
                Text("Sensor")
            }

            Section {
                if let activatedAt = record.activatedAt {
                    SibionicsSectionItem(title: Text("Started at"), value: Self.dateTime.string(from: activatedAt))
                }
                if let pairedAt = record.pairedAt {
                    SibionicsSectionItem(title: Text("Paired"), value: Self.dateTime.string(from: pairedAt))
                }
                if let endedAt = record.endedAt {
                    SibionicsSectionItem(title: endLabel, value: Self.dateTime.string(from: endedAt))
                    if let activatedAt = record.activatedAt {
                        SibionicsSectionItem(
                            title: Text("Worn for"),
                            value: Self.duration.string(from: endedAt.timeIntervalSince(activatedAt)) ?? "-"
                        )
                    }
                }
            } header: {
                Text("Session")
            }
        }
        .listStyle(InsetGroupedListStyle())
    }

    private var endLabel: Text {
        switch record.endReason {
        case .replaced: Text("Replaced")
        case .failed: Text("Failed")
        case .sessionEnded: Text("Session ended")
        case .ended,
             nil: Text("Ended")
        }
    }
}
