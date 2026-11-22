import Foundation

/// Sensor lifecycle alerts, raised through LoopKit's alert pipeline.
///
/// Until this existed nothing was ever raised: `acknowledgeAlert` was a no-op
/// and `getSounds()` returned nothing, so a sensor that failed or went quiet did
/// so in silence. For a CGM that is a missing feature, not a detail.
///
/// Interruption levels follow the sibling kits: something that has already
/// stopped the readings is `critical`, something about to is `timeSensitive`.
///
/// Delivery is the *host's* job — Loop routes these through `AlertManager`, Trio
/// through `TrioAlertManager`. Older Trio builds discarded plugin alerts, so an
/// alert issued here is not proof the user saw it.
///
/// The LoopKit `Alert` itself is built in `CGMManager+Alerts.swift`, because
/// everything under `Services/` is excluded from the SwiftPM build and this file
/// has to stay testable without a workspace.
public enum SibionicsAlert: String, CaseIterable, Sendable {
    /// No record has arrived for a while with the sensor still paired.
    case signalLoss
    /// The driver has concluded the sensor is dead (`SibionicsSensorFault`).
    case sensorFailed
    /// 14 days are up.
    case sensorExpired

    public var identifier: String { rawValue }

    public var title: String {
        switch self {
        case .signalLoss:
            return LocalizedString("No sensor readings", comment: "Alert title: readings have stopped")
        case .sensorFailed:
            return LocalizedString("Sensor failed", comment: "Alert title: sensor has failed")
        case .sensorExpired:
            return LocalizedString("Sensor session ended", comment: "Alert title: sensor has expired")
        }
    }

    public var body: String {
        switch self {
        case .signalLoss:
            return LocalizedString(
                "No readings have arrived from your Sibionics sensor for 20 minutes. Keep your phone near the sensor. If this continues, check your glucose with a fingerstick meter.",
                comment: "Alert body: readings have stopped"
            )
        case .sensorFailed:
            return LocalizedString(
                "Your Sibionics sensor has stopped producing usable readings. Remove it and start a new one. Check your glucose with a fingerstick meter in the meantime.",
                comment: "Alert body: sensor has failed"
            )
        case .sensorExpired:
            return LocalizedString(
                "Your Sibionics sensor has reached the end of its 14 days, so no new readings will arrive. Start a new sensor when you are ready.",
                comment: "Alert body: sensor has expired"
            )
        }
    }
}

/// Which alerts should currently be up. Pure, so it can be tested without a
/// sensor, a delegate or a clock.
public enum SibionicsAlertEvaluator {
    /// Long enough that a normal reconnect or a couple of skipped packets does
    /// not fire it; short enough to be useful. Matches the sibling kits.
    public static let signalLossAfter: TimeInterval = 20 * 60
    /// After launch, how long signal loss waits for the first reconnect. The
    /// last reading is old after any long quit, so without this the alert is
    /// raised before the app has tried to connect and withdrawn seconds later.
    /// Two minutes covers a slow connect (one timed out after 79 s).
    public static let launchGrace: TimeInterval = 2 * 60

    /// - Parameters:
    ///   - sensorPaired: a sensor is stored, so these alerts are meaningful.
    ///   - latestReadingAt: when the last record arrived; nil before the first.
    ///   - reportedFault: the driver's own verdict that the sensor is dead.
    ///   - expired: the wear window is over.
    ///   - launchedAt: when the app started; signal loss waits `launchGrace`
    ///     after it. `nil` applies no grace.
    public static func dueAlerts(
        sensorPaired: Bool,
        latestReadingAt: Date?,
        reportedFault: SibionicsSensorFault.Kind?,
        expired: Bool,
        launchedAt: Date? = nil,
        now: Date = Date()
    ) -> Set<SibionicsAlert> {
        guard sensorPaired else { return [] }

        var due: Set<SibionicsAlert> = []
        if reportedFault != nil { due.insert(.sensorFailed) }
        if expired { due.insert(.sensorExpired) }

        // Signal loss says nothing useful once the sensor is known to be gone:
        // it would only be a second alert for the same event.
        let settled = launchedAt.map { now.timeIntervalSince($0) >= launchGrace } ?? true
        if due.isEmpty, settled, let last = latestReadingAt, now.timeIntervalSince(last) >= signalLossAfter {
            due.insert(.signalLoss)
        }
        return due
    }
}
