import Foundation
import LoopKit
import LoopKitUI
import SibionicsKit
import SwiftUI
import UIKit

// `CGMManagerUI` is declared in LoopKitUI and cannot be retroactively
// conformed to from the framework that defines the type, so the conformance
// lives here, next to the views.
extension SibionicsCGMManager: @retroactive CGMManagerUI {
    public static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool,
        prefersToSkipUserInteraction _: Bool = false
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        .userInteractionRequired(SibionicsUIController(
            colorPalette: colorPalette,
            displayGlucosePreference: displayGlucosePreference,
            allowDebugFeatures: allowDebugFeatures
        ))
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference: DisplayGlucosePreference,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures: Bool
    ) -> CGMManagerViewController {
        SibionicsUIController(
            cgmManager: self,
            colorPalette: colorPalette,
            displayGlucosePreference: displayGlucosePreference,
            allowDebugFeatures: allowDebugFeatures
        )
    }

    /// The kit's own sensor artwork, used by the picker and onboarding.
    public static var onboardingImage: UIImage? {
        UIImage(named: "sensor", in: .sibionicsUI, compatibleWith: nil)
    }

    public var smallImage: UIImage? { Self.onboardingImage }

    public var cgmStatusHighlight: DeviceStatusHighlight? {
        switch sensorLifecycle {
        case .noSensor:
            return nil
        case .warmup:
            return SibionicsStatusHighlight(
                localizedMessage: String(localized: "Sensor\nWarmup", comment: "Status highlight: warmup"),
                imageName: "clock",
                state: .normalCGM
            )
        case .active:
            return nil
        case .expired:
            return SibionicsStatusHighlight(
                localizedMessage: String(localized: "Sensor\nExpired", comment: "Status highlight: expired"),
                imageName: "clock",
                state: .warning
            )
        case .signalLost:
            return SibionicsStatusHighlight(
                localizedMessage: String(localized: "Signal\nLoss", comment: "Status highlight: signal loss"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        case .failed:
            return SibionicsStatusHighlight(
                localizedMessage: String(localized: "Sensor\nFailed", comment: "Status highlight: failed"),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }
    }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? {
        switch sensorLifecycle {
        case let .warmup(progress, _):
            return SibionicsLifecycleProgress(percentComplete: progress, progressState: .normalCGM)
        case let .active(remaining, total):
            guard total > 0 else { return nil }
            return SibionicsLifecycleProgress(
                percentComplete: max(0, min(1, 1 - remaining / total)),
                progressState: remaining < 24 * 60 * 60 ? .warning : .normalCGM
            )
        case .expired:
            return SibionicsLifecycleProgress(percentComplete: 1, progressState: .critical)
        default:
            return nil
        }
    }

    public var cgmStatusBadge: DeviceStatusBadge? { nil }
}

struct SibionicsStatusHighlight: DeviceStatusHighlight {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}

struct SibionicsLifecycleProgress: DeviceLifecycleProgress {
    let percentComplete: Double
    let progressState: DeviceLifecycleProgressState
}
