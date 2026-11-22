import LoopKit
import LoopKitUI
import SibionicsKit
import SwiftUI
import UIKit

final class SibionicsUIController: UINavigationController, CGMManagerOnboarding, CompletionNotifying {
    weak var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    private let cgmManager: SibionicsCGMManager
    private var model: SibionicsCGMState?
    private let isInitialSetup: Bool
    private let debugEnabled: Bool
    private let displayGlucosePreference: DisplayGlucosePreference
    private let colorPalette: LoopUIColorPalette

    init(
        cgmManager: SibionicsCGMManager? = nil,
        colorPalette: LoopUIColorPalette,
        displayGlucosePreference: DisplayGlucosePreference,
        allowDebugFeatures: Bool
    ) {
        isInitialSetup = cgmManager == nil
        debugEnabled = allowDebugFeatures
        self.displayGlucosePreference = displayGlucosePreference
        self.colorPalette = colorPalette
        self.cgmManager = cgmManager ?? SibionicsCGMManager()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
        let model = SibionicsCGMState(manager: cgmManager)
        self.model = model

        let needsOnboarding = isInitialSetup && cgmManager.state.mac == nil
        if isInitialSetup, !needsOnboarding {
            // Restored an existing sensor: this manager already has something to
            // manage, so finish onboarding immediately.
            cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: cgmManager)
            cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: cgmManager)
        }

        if needsOnboarding {
            setViewControllers(
                [hostingController(
                    SibionicsOnboardingView(
                        model: model,
                        onFinish: { [weak self] in self?.finishOnboarding() },
                        onCancel: { [weak self] in self?.cancelOnboarding() }
                    ),
                    title: String(localized: "Add Sibionics sensor"),
                    largeTitle: false
                )],
                animated: false
            )
        } else {
            showSettings(for: model)
        }
    }

    /// SwiftUI's `.navigationTitle` does not reach the nav bar of a sheet
    /// presented this way, so the title goes on the hosting controller — and
    /// `DismissibleHostingController` is what supplies the guidance colours,
    /// the dismiss action and the Done button the sheet needs.
    private func hostingController(
        _ content: some View,
        title: String,
        largeTitle: Bool
    ) -> DismissibleHostingController<AnyView> {
        let host = DismissibleHostingController(
            content: AnyView(content.environmentObject(displayGlucosePreference)),
            colorPalette: colorPalette
        )
        host.navigationItem.title = title
        host.navigationItem.largeTitleDisplayMode = largeTitle ? .always : .never
        return host
    }

    private func showSettings(for model: SibionicsCGMState) {
        let settings = SibionicsSettingsView(
            model: model,
            debugEnabled: debugEnabled,
            onShowAccountID: { [weak self] in self?.showAccountID(for: model) },
            onShowPreviousSensor: { [weak self] in self?.showPreviousSensor(for: model) }
        )
        setViewControllers(
            [hostingController(settings, title: String(localized: "Sibionics GS3"), largeTitle: true)],
            animated: true
        )
    }

    /// Pushed through UIKit rather than a SwiftUI `NavigationLink`: this
    /// controller owns the navigation bar, and a SwiftUI destination pushed into
    /// it inherits neither `navigationTitle` nor the title-display mode, which
    /// left the bar empty and tall. Same reason the settings title is set here.
    private func showAccountID(for model: SibionicsCGMState) {
        let editor = SibionicsAccountIDEditor(model: model) { [weak self] in
            self?.popViewController(animated: true)
        }
        pushViewController(
            hostingController(editor, title: String(localized: "Account ID"), largeTitle: false),
            animated: true
        )
    }

    private func showPreviousSensor(for model: SibionicsCGMState) {
        guard let record = model.previousSensor else { return }
        pushViewController(
            hostingController(
                SibionicsPreviousSensorView(record: record),
                title: String(localized: "Previous Sensor"),
                largeTitle: false
            ),
            animated: true
        )
    }

    /// Nothing was created yet, so there is nothing to report to the
    /// onboarding delegate; completing just dismisses the flow.
    private func cancelOnboarding() {
        completionDelegate?.completionNotifyingDidComplete(self)
    }

    private func finishOnboarding() {
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didCreateCGMManager: cgmManager)
        cgmManagerOnboardingDelegate?.cgmManagerOnboarding(didOnboardCGMManager: cgmManager)
        if let model {
            showSettings(for: model)
        }
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}
