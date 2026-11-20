import Foundation
@preconcurrency import LoopKit

/// The LoopKit adapter around the Rust `cgm-sibionics` engine (OS-AID
/// guideline 13): commands go in through `run`, events come out through
/// `handle`. `SibionicsRustHost` performs the engine's actions.
extension SibionicsCGMManager {
    /// The variant is the registration key the sensor was sold for.
    static func variant(for registrationKey: Data) -> String {
        switch registrationKey {
        case SibionicsRegistrationKey.russian: return "gs3-ru"
        case SibionicsRegistrationKey.sensing: return "gs3-sensing"
        default: return "gs3"
        }
    }

    @MainActor func engineHost() throws -> SibionicsRustHost {
        if let engine { return engine }
        let host = try SibionicsRustHost(
            variant: Self.variant(for: state.activeRegistrationKey),
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            },
            onLinkLost: { [weak self] in
                Task { @MainActor in self?.handleLinkLost() }
            }
        )
        engine = host
        return host
    }

    /// Submits a command and waits for its one `Finished` (E5).
    @MainActor func run(_ command: FfiCommand) async throws -> FfiOutcome {
        let host = try engineHost()
        return try await withCheckedThrowingContinuation { continuation in
            do {
                // Events are delivered on the main actor, which is busy here,
                // so the outcome cannot arrive before it is awaited.
                let id = try host.submit(command)
                pendingCommands[id] = continuation
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    static func describe(_ outcome: FfiOutcome) -> String {
        switch outcome {
        case .completed: return "done"
        case .unknown:
            return LocalizedString(
                "The sensor may or may not have been started. Pair again to find out; it will not be started twice.",
                comment: "Pairing: unknown outcome"
            )
        case let .refused(refusal): return "refused: \(refusal)"
        case .failed(.keyRejected):
            return LocalizedString(
                "The sensor refused this account id — it was started with a different one.",
                comment: "Pairing: key rejected"
            )
        case .failed(.wrongDevice):
            return LocalizedString(
                "This is not the sensor on the scanned applicator.",
                comment: "Pairing: wrong sensor"
            )
        case .failed(.unsupportedDevice):
            return LocalizedString(
                "This sensor's firmware generation is not supported (V3 only).",
                comment: "Pairing: unsupported"
            )
        case let .failed(failure): return "failed: \(failure)"
        }
    }

    @MainActor func handle(_ event: FfiEvent) {
        switch event {
        case let .finished(id, outcome):
            pendingCommands.removeValue(forKey: id)?.resume(returning: outcome)
        case let .reading(reading):
            ingest(reading)
        case let .backfillAvailable(after):
            backfill(after: UInt16(clamping: after))
        case let .sensorStateChanged(sensorState):
            switch sensorState {
            case .failed:
                markSensorFailed(SibionicsSensorFault(kind: .signalImplausible))
            case .signalLost:
                // The stale-link watchdog: no records for six minutes means a
                // zombie link; drop it so the reconnect starts afresh.
                logger.debug("no records for six minutes; forcing a reconnect")
                engine?.disconnect()
            default:
                break
            }
            evaluateAlerts()
        case let .deviceInfo(info):
            engineDeviceInfo = info
            if let ms = info.activationMs {
                persistActivation(Date(timeIntervalSince1970: TimeInterval(ms) / 1000))
            }
        case let .log(level, line):
            switch level {
            case 3...: logger.error(line)
            case 2: logger.warning(line)
            default: logger.debug(line)
            }
        case .started, .stateChanged:
            break
        }
    }
}
