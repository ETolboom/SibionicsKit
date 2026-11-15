import LoopKitUI
import SwiftUI

/// First screen of onboarding: what this is, the sensor, and the two things you
/// might want to do next.
///
/// Laid out like `SyaiOnboardingView`: the artwork and a short introduction in a
/// list, then the primary actions pinned to the bottom, secondary first and
/// primary last, with `ActionButtonStyle` supplying both.
struct SibionicsOnboardingLandingView: View {
    var onShowPlacement: () -> Void
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Spacer()
                            Image(imageName: "sensor")
                                .resizable()
                                .scaledToFit()
                                .frame(height: 150)
                                .padding(.bottom, 10)
                            Spacer()
                        }
                        Text("Before you begin")
                            .font(.title3)
                            .bold()
                        Text(
                            "Apply the sensor first, then connect to it here. A GS3 can connect to more than one device, but the official app may interfere with Trio, so we recommend keeping it closed while Trio is using it."
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer()

            VStack(spacing: 10) {
                Button(action: onShowPlacement) {
                    Text("Placement Guide")
                }
                .buttonStyle(ActionButtonStyle(.secondary))

                Button(action: onContinue) {
                    Text("Continue")
                }
                .buttonStyle(ActionButtonStyle())
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}
