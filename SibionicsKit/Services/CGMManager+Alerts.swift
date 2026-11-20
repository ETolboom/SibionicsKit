import Foundation
import LoopKit

/// LoopKit-side half of `SibionicsAlert`: the interruption level and the
/// `Alert` itself, which cannot live in `Sensor/` because that directory is part
/// of the workspace-free SwiftPM build.
public extension SibionicsAlert {
    var interruptionLevel: Alert.InterruptionLevel {
        switch self {
        case .sensorExpired,
             .signalLoss: return .timeSensitive
        case .sensorFailed: return .critical
        }
    }

    func alert(managerIdentifier: String) -> Alert {
        let content = Alert.Content(
            title: title,
            body: body,
            acknowledgeActionButtonLabel: LocalizedString("OK", comment: "Alert acknowledgement button")
        )
        return Alert(
            identifier: Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: identifier),
            foregroundContent: content,
            backgroundContent: content,
            trigger: .immediate,
            interruptionLevel: interruptionLevel
        )
    }
}

/// Raises and retracts the lifecycle alerts from `SibionicsAlert`.
///
/// The reconciler shape follows the sibling kits: work out which alerts *should*
/// be up, diff that against which ones are, act only on the difference, and keep
/// the record in step. Calling this often is safe and intended.
@MainActor
extension SibionicsCGMManager {
    /// How often the monitor is polled for alerts that cannot be event-driven.
    /// Signal loss is defined by the *absence* of an event, so it needs a clock.
    static let alertTick: TimeInterval = 60

    func evaluateAlerts(now: Date = Date()) {
        let expired: Bool
        if case .expired = sensorLifecycle { expired = true } else { expired = false }

        let due = SibionicsAlertEvaluator.dueAlerts(
            sensorPaired: state.mac != nil,
            latestReadingAt: state.latestReadingTimestamp,
            reportedFault: state.sensorFault,
            expired: expired,
            now: now
        )
        guard due != raisedAlerts else { return }

        let toIssue = due.subtracting(raisedAlerts)
        let toRetract = raisedAlerts.subtracting(due)
        raisedAlerts = due

        for kind in toIssue {
            logger.info("issuing alert \(kind.rawValue)")
            let alert = kind.alert(managerIdentifier: Self.pluginIdentifier)
            Task { [weak self] in await self?.cgmManagerDelegate?.issueAlert(alert) }
        }
        for kind in toRetract {
            logger.info("retracting alert \(kind.rawValue)")
            let identifier = Alert.Identifier(
                managerIdentifier: Self.pluginIdentifier,
                alertIdentifier: kind.identifier
            )
            Task { [weak self] in await self?.cgmManagerDelegate?.retractAlert(identifier: identifier) }
        }
    }

    /// Signal loss cannot be event-driven, so the timer covers exactly that.
    func startAlertTicker() {
        guard alertTicker == nil else { return }
        alertTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.alertTick * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    // The same tick moves the engine's clock (warm-up, wear,
                    // signal loss).
                    self.engine?.tick()
                    self.evaluateAlerts()
                }
            }
        }
    }

    func stopAlertTicker() {
        alertTicker?.cancel()
        alertTicker = nil
        raisedAlerts = []
    }
}
