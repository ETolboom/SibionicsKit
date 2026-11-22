import SwiftUI
import UIKit

/// Model, sensor ID, serial and firmware: what identifies a sensor, shared by
/// the settings screen and the Previous Sensor page (as G7SensorKit's
/// `G7SensorIdentityRows`). The sensor ID and serial copy on tap. The caller
/// supplies the `Section`.
struct SibionicsSensorIdentityRows: View {
    let model: String
    /// The MAC, printed on the packaging. It is not the account id.
    let sensorID: String?
    let serial: String?
    let firmware: String?

    @State private var copiedValue: String?

    var body: some View {
        SibionicsSectionItem(title: Text("Model"), value: model)
        if let sensorID {
            copyableRow(title: Text("Sensor ID"), value: sensorID)
        }
        if let serial {
            copyableRow(title: Text("Serial"), value: serial)
        }
        if let firmware, !firmware.isEmpty {
            SibionicsSectionItem(title: Text("Firmware"), value: firmware)
        }
    }

    /// A value row that copies on tap (and offers Copy in its context menu),
    /// confirming briefly in place.
    private func copyableRow(title: Text, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            withAnimation { copiedValue = value }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation {
                    if copiedValue == value { copiedValue = nil }
                }
            }
        } label: {
            HStack {
                title.foregroundColor(.primary)
                Spacer()
                if copiedValue == value {
                    Text("Copied").foregroundColor(.secondary)
                } else {
                    Text(value).foregroundColor(.secondary)
                    Image(systemName: "doc.on.doc")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
        .contextMenu {
            Button {
                UIPasteboard.general.string = value
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }
}
