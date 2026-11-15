import LoopKitUI
import SwiftUI

/// How to apply a GS3 sensor, in the app's own six steps.
///
/// **The wording is the manufacturer's, copied verbatim** from the official
/// app's localisation table — the `step_N_*` titles and their `step_N_guide_*`
/// tips and notices, plus `wipe_upper_arm_with_alcohol_and_dry` and
/// `gently_pull_sensor_applicator`. Where that table has a typo ("Unsrew") it is
/// reproduced rather than corrected, so the guide says what the vendor's guide
/// says. Keep it that way when editing: these are instructions for a medical
/// device, and paraphrasing them invents risk.
///
/// The illustrations are the official app's own `img_apply_sensor1…6`, copied
/// into this kit's asset catalog as `placement_step1…6`. They are the
/// manufacturer's drawings of its own product, not artwork authored here.
///
/// Structure follows `SyaiSensorPlacementView`: one card per step in a pager,
/// dot indicators, Back/Next/Done pinned in the footer.
struct SibionicsSensorPlacementView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var step = 0
    private static let stepCount = 6

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $step) {
                    ForEach(0 ..< Self.stepCount, id: \.self) { index in
                        ScrollView {
                            stepView(index + 1).padding()
                        }
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                footer
            }
            .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Placement Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private func stepView(_ number: Int) -> some View {
        switch number {
        case 1:
            stepCard(
                number,
                Text("Step 1 Choose Sensor Site"),
                image: "placement_step1"
            ) {
                Text("Find this location on the back of your upper arm.")
                callout(.note, Text("Note")) {
                    bullet(Text("Avoid areas with wounds or skin irritation."))
                    bullet(Text("Note: Avoid areas with wounds or insulin injection site."))
                }
            }

        case 2:
            stepCard(
                number,
                Text("Step 2 Clean and Dry Site"),
                image: "placement_step2"
            ) {
                Text("Clean location with alcohol wipe and wait for skin to dry.")
                callout(.note, Text("Note")) {
                    bullet(Text("Wait for skin to dry completely so sensor will adhere properly."))
                }
            }

        case 3:
            stepCard(
                number,
                Text("Step 3 Unscrew Cap"),
                image: "placement_step3"
            ) {
                Text("Unsrew cap from Sensor Applicator.")
                callout(.caution, Text("Caution")) {
                    bullet(Text("Do not try to put cap back on as it may damage the sensor."))
                    bullet(Text("Do not touch inside as there is a needle."))
                }
            }

        case 4:
            stepCard(
                number,
                Text("Step 4 Use Applicator to Apply"),
                image: "placement_step4"
            ) {
                Text(
                    "Place Sensor Applicator over location site. Push down the button on top of the Applicator to release the sensor."
                )
                callout(.caution, Text("Caution")) {
                    bullet(
                        Text(
                            "Do NOT push down on the button before the Applicator is placed over the location site, or the sensor will be released early."
                        )
                    )
                }
            }

        case 5:
            stepCard(
                number,
                Text("Step 5 Remove Applicator"),
                image: "placement_step5"
            ) {
                Text("Gently pull the Sensor Applicator away from your body.")
            }

        default:
            stepCard(
                number,
                Text("Step 6 Rub Patch"),
                image: "placement_step6"
            ) {}
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0 ..< Self.stepCount, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            HStack(spacing: 12) {
                if step > 0 {
                    Button {
                        withAnimation { step -= 1 }
                    } label: {
                        Text("Back")
                    }
                    .buttonStyle(ActionButtonStyle(.secondary))
                }

                if step < Self.stepCount - 1 {
                    Button {
                        withAnimation { step += 1 }
                    } label: {
                        Text("Next")
                    }
                    .buttonStyle(ActionButtonStyle())
                } else {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                    .buttonStyle(ActionButtonStyle())
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private func stepCard<Content: View>(
        _ number: Int,
        _ title: Text,
        image: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(verbatim: "\(number)")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.accentColor))
                title
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Image(imageName: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(maxHeight: 200)
                .background(Color(UIColor.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            content()
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private enum CalloutKind {
        case note
        case caution

        var systemImage: String {
            switch self {
            case .note: return "info.circle.fill"
            case .caution: return "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .note: return .accentColor
            case .caution: return .orange
            }
        }
    }

    private func callout<Content: View>(
        _ kind: CalloutKind,
        _ title: Text,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                title.font(.subheadline.weight(.semibold))
            } icon: {
                Image(systemName: kind.systemImage)
            }
            .foregroundColor(kind.color)

            VStack(alignment: .leading, spacing: 6) {
                content()
            }
            .font(.footnote)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func bullet(_ text: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: "•")
            text
            Spacer(minLength: 0)
        }
    }
}
