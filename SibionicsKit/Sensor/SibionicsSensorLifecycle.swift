import Foundation

/// Warmup / active / expired / signal-loss, computed from the sensor's own
/// clock wherever possible.
///
/// The GS3 reports its activation and current time (`0xF0 0x03`), so age does
/// not have to be inferred from the phone's clock. That matters more here than
/// on most CGMs: the activation timestamp is written once by us and can never
/// be corrected, so any drift in it would otherwise silently shift every
/// reading's date.
public enum SibionicsSensorLifecycle: Equatable {
    case noSensor
    case warmup(progress: Double, remaining: TimeInterval)
    case active(remaining: TimeInterval, total: TimeInterval)
    case expired
    case signalLost(since: Date)
    case failed

    /// Three missed one-minute records before the driver calls it signal loss.
    public static let signalLostThreshold: TimeInterval = 6 * 60

    public static func age(
        activatedAt: Date?,
        sensorAge: (elapsed: TimeInterval, at: Date)?,
        now: Date = Date()
    ) -> TimeInterval? {
        if let sensorAge { return sensorAge.elapsed + now.timeIntervalSince(sensorAge.at) }
        return activatedAt.map { now.timeIntervalSince($0) }
    }

    public static func compute(
        sensorPaired: Bool,
        activatedAt: Date?,
        sensorAge: (elapsed: TimeInterval, at: Date)? = nil,
        latestReadingAt: Date?,
        hasLiveMonitor: Bool,
        reportedFault: SibionicsSensorFault.Kind? = nil,
        activeDuration: TimeInterval? = nil,
        warmupDuration: TimeInterval? = nil,
        now: Date = Date()
    ) -> SibionicsSensorLifecycle {
        guard sensorPaired else { return .noSensor }
        if reportedFault != nil { return .failed }

        guard let activatedAt, let wear = activeDuration, let warmup = warmupDuration else {
            return .noSensor
        }
        let age = Self.age(activatedAt: activatedAt, sensorAge: sensorAge, now: now) ?? 0
        if age >= wear { return .expired }
        if age < warmup {
            return .warmup(progress: warmup > 0 ? age / warmup : 1, remaining: warmup - age)
        }
        let stale = latestReadingAt.map { abs(now.timeIntervalSince($0)) > signalLostThreshold } ?? !hasLiveMonitor
        if stale { return .signalLost(since: latestReadingAt ?? activatedAt) }
        return .active(remaining: wear - age, total: wear)
    }

    public var displayName: String {
        switch self {
        case .noSensor: return LocalizedString("No sensor", comment: "Lifecycle: none")
        case .warmup: return LocalizedString("Warming up", comment: "Lifecycle: warmup")
        case .active: return LocalizedString("Active", comment: "Lifecycle: active")
        case .expired: return LocalizedString("Expired", comment: "Lifecycle: expired")
        case .signalLost: return LocalizedString("Signal loss", comment: "Lifecycle: signal lost")
        case .failed: return LocalizedString("Sensor failed", comment: "Lifecycle: failed")
        }
    }

    public static func faultDetail(for kind: SibionicsSensorFault.Kind) -> String {
        switch kind {
        case .signalImplausible:
            return LocalizedString(
                "Sensor readings implausible, consider replacing sensor",
                comment: "Status: implausible readings"
            )
        }
    }
}
