import CoreBluetooth
import Foundation

/// Connecting, authenticating, and (optionally) activating a sensor.
///
/// Deliberately split from `SibionicsBLECentral`: this is the only place that
/// decides to *write* an activation command, and the gate for that lives here so
/// there is exactly one code path that can consume a sensor.
public final class SibionicsPairingService {
    public enum Stage: Sendable, Equatable {
        case discovering
        case connecting
        case readingDeviceInfo
        case authenticating
        case activating
        case confirmingActivation
        case startingSession
    }

    public enum Failure: Error, LocalizedError, CustomStringConvertible {
        case noSensorSelected
        case sensorNotFound
        case missingMAC
        /// The sensor did not report a usable serial number, so there is no IV.
        case noSerialNumber
        /// An applicator tag was scanned, and the sensor we attached to reports
        /// a different product serial. Wrong sensor in range, or the wrong tag.
        case serialMismatch(expected: String, reported: String)
        /// The sensor reports a protocol generation this driver does not speak.
        case unsupportedGeneration(String)
        /// The user has not enabled activation. Reading an already-activated
        /// sensor needs no consent; starting a new one does.
        /// The activation command was written but the sensor still reports no
        /// activation stamp. This is the dangerous case: the sensor may now be
        /// running on a clock we cannot see, and it is single-use.
        case activationNotConfirmed
        case accountMissing
        /// The sensor answered auth with a refusal. For a fresh sensor this
        /// means the id was not acceptable; for an activated one it means it is
        /// bound to a different id.
        case accountRejected(status: String?)
        case session(SibionicsSession.SessionError)
        case ble(String)

        public var description: String {
            switch self {
            case .noSensorSelected: return "Choose a sensor first."
            case .sensorNotFound: return "That sensor is not in range."
            case .missingMAC:
                return "A sensor MAC is required: the transport cipher is keyed from it."
            case let .serialMismatch(expected, reported):
                return "That is a different sensor: the tag says \(expected) but the sensor says \(reported). "
                    + "Move closer to the sensor whose tag you scanned and try again."
            case .noSerialNumber:
                return "The sensor did not report a serial number, and the cipher key is derived from it. "
                    + "Enter the MAC printed on the sensor instead."
            case let .unsupportedGeneration(detail):
                return "This sensor is not a supported generation (\(detail)). Only V3 sensors are supported."
            case .activationNotConfirmed:
                return "The activation command was sent but the sensor does not report an activation time. Do not use this sensor for dosing; check the logs."
            case .accountMissing:
                return "A Sibionics account id is required."
            case let .accountRejected(status):
                let code = status ?? "none"
                return "The sensor refused this account id (status \(code)). "
                    + "If it was activated by the official app, enter the account id that app used; "
                    + "a fresh sensor should accept a generated one. Nothing was written to the sensor."
            case let .session(error): return error.description
            case let .ble(detail): return detail
            }
        }

        public var errorDescription: String? { description }
    }

    public struct Outcome {
        public let monitor: SibionicsSensorMonitor
        public let deviceInfo: SibionicsDeviceInfo
        /// Nil when the sensor is activated but neither its clock nor a stored
        /// value says when — the monitor learns it from the first record.
        public let activatedAt: Date?
        public let didActivate: Bool
        /// `F0 0E` value, when the sensor answered it.
        public let serial: String?
    }

    private let logger = SibionicsLogger(category: "Pairing")
    private let central: SibionicsBLECentral

    public init(central: SibionicsBLECentral = .shared) {
        self.central = central
    }

    public func discover() async throws -> [SibionicsBLECentral.DiscoveredSensor] {
        do {
            return try await central.discoverSensors()
        } catch {
            throw Failure.ble(error.localizedDescription)
        }
    }

    /// Connects, authenticates and returns a live monitor. If `activate` is
    /// true and the sensor reports no activation stamp, the `0x35` command is
    /// written first and then confirmed.
    /// `mac` may be nil: the sensor's own serial number characteristic is the
    /// MAC, and it can be read over GATT before anything is decrypted, so
    /// pairing normally needs nothing from the applicator or the box.
    /// What pairing should do with the sensor, decided only by its clock.
    ///
    /// The whole activation policy: **a sensor is activated only when the clock
    /// query answered and reported `activation_time == 0`.** A clock reply that
    /// never arrived is not evidence of anything, and activating on that guess
    /// would stamp a running sensor with a new start time and a new account id.
    public enum ActivationDecision: Equatable, Sendable {
        case alreadyActivated(Date)
        case attachReadOnly
        case activate
    }

    public static func activationDecision(
        clockAnswered: Bool,
        activationDate: Date?,
        knownActivatedAt: Date?
    ) -> ActivationDecision {
        if let existing = activationDate ?? knownActivatedAt {
            return .alreadyActivated(existing)
        }
        guard clockAnswered else { return .attachReadOnly }
        return .activate
    }

    public func attach(
        peripheralID: UUID,
        mac: String?,
        accountID: SibionicsAccountID,
        registrationKey: Data,
        warmup: TimeInterval,
        activeDuration: TimeInterval,
        /// Activation time we already hold for this sensor, used when the
        /// sensor's clock is unavailable so a reconnect can still date records.
        knownActivatedAt: Date? = nil,
        /// Product serial from an applicator tag, verified against `F0 0E` once
        /// authenticated. Read-only check; nothing is written either way.
        expectedSerial: String? = nil,
        onStage: @Sendable @escaping (Stage) -> Void = { _ in }
    ) async throws -> Outcome {
        onStage(.connecting)
        let transport: SibionicsBLEPeripheral
        do {
            transport = try await central.connect(peripheralID: peripheralID)
        } catch {
            throw Failure.ble(error.localizedDescription)
        }

        do {
            onStage(.readingDeviceInfo)
            // The serial number characteristic *is* the MAC. Reading it here
            // means no NFC scan, no typing, and no risk of the wrong byte
            // order: this is the same value the auth frame carries.
            let serial = (try? await transport.read(SibionicsGATT.serialNumber))
                .flatMap { String(data: $0, encoding: .utf8) }
            let chosen = mac?.trimmingCharacters(in: .whitespaces) ?? serial
            let normalisedMAC = SibionicsSession.normalise(chosen ?? "")
            guard SibionicsCipher.isValidMAC(normalisedMAC) else {
                logger.error("no usable MAC: serial=\"\(serial ?? "nil")\" supplied=\"\(mac ?? "nil")\"")
                throw Failure.noSerialNumber
            }

            let info = try await readDeviceInfo(transport: transport, mac: normalisedMAC)
            guard info.protocolGeneration == .v3 else {
                throw Failure.unsupportedGeneration(info.protocolVersion.description)
            }

            onStage(.authenticating)
            let session: SibionicsSession
            do {
                session = try SibionicsSession(transport: transport, mac: normalisedMAC, firmware: info.protocolVersion)
            } catch {
                throw Failure.session(.undecryptable)
            }
            // Subscribe to `ff31` and wait for the CCCD acknowledgement *before*
            // the first request. Without the wait the auth write can beat the
            // notification enable and the reply is silently discarded.
            do {
                try await session.start()
            } catch {
                session.close()
                throw Failure.session(.notSubscribed)
            }

            let activatedAt: Date?
            let didActivate: Bool

            // Reading the clock is itself the auth probe: an unauthenticated
            // sensor answers with the bootstrap frame, which the session
            // surfaces as `.unauthenticated`.
            do {
                try await session.authenticate(registrationKey: registrationKey, accountID: accountID)
            } catch let error as SibionicsSession.SessionError {
                session.close()
                if case let .authenticationRejected(status) = error {
                    throw Failure.accountRejected(status: status.map { String(format: "0x%02x", $0) })
                }
                throw Failure.session(error)
            } catch {
                session.close()
                throw Failure.ble(error.localizedDescription)
            }

            // Not fatal: the official app never asks for the clock, so a
            // firmware that ignores `0xF0 0x03` must not block the session.
            var reportedSerial: String?
            if let expectedSerial {
                reportedSerial = try? await session.deviceSerial()
                if let reportedSerial, reportedSerial.caseInsensitiveCompare(expectedSerial) != .orderedSame {
                    session.close()
                    logger.error("tag/sensor mismatch: tag=\(expectedSerial) sensor=\(reportedSerial)")
                    throw Failure.serialMismatch(expected: expectedSerial, reported: reportedSerial)
                }
                if reportedSerial == nil {
                    logger.warning("tag serial \(expectedSerial) could not be verified (no F0 0E reply)")
                } else {
                    logger.info("tag serial verified against the sensor: \(reportedSerial!)")
                }
            }

            let clock = knownActivatedAt == nil ? try? await session.deviceTime() : nil
            let decision = Self.activationDecision(
                clockAnswered: clock != nil,
                activationDate: clock?.activationDate,
                knownActivatedAt: knownActivatedAt
            )

            if case let .alreadyActivated(existing) = decision {
                logger.info("attaching to an already-activated sensor, started \(existing)")
                activatedAt = existing
                didActivate = false
            } else if case .attachReadOnly = decision {
                logger.warning(
                    "activation state unknown (no clock reply); attaching read-only and learning the start time"
                )
                activatedAt = knownActivatedAt
                didActivate = false
            } else {
                // The sensor answered `F0 03` with `activation_time == 0`: it is
                // factory-new, and the only thing pairing it can mean is to
                // activate it. This is the sole activation trigger.
                onStage(.activating)
                let start = Date()
                logger.warning("ACTIVATING sensor \(SibionicsRedact.mac(normalisedMAC)) at \(start)")
                let ack: SibionicsSession.ActivationAck
                do {
                    // Strict: throws unless the sensor answered status 0x01 and
                    // echoed the timestamp we sent.
                    ack = try await session.activateBindIn(activationTime: start, accountID: accountID)
                } catch let error as SibionicsSession.SessionError {
                    session.close()
                    throw Failure.session(error)
                }

                onStage(.confirmingActivation)
                activatedAt = ack.activationDate
                didActivate = true
                logger.warning("activation confirmed by the ack, sensor started \(ack.activationDate)")

                // The clock query is a nice independent check, but the sensor is
                // not required to answer it (the official app never asks), so a
                // failure here must not undo a confirmed activation.
                if let time = try? await session.deviceTime(), let reported = time.activationDate {
                    if abs(reported.timeIntervalSince(ack.activationDate)) > 2 {
                        logger.warning("device clock says \(reported), ack said \(ack.activationDate)")
                    }
                }
            }

            // Same sensor, with the user's (configurable) timings attached.
            let deviceInfo = SibionicsDeviceInfo(
                mac: info.mac,
                model: info.model,
                serial: info.serial,
                softwareRevision: info.softwareRevision,
                protocolGeneration: info.protocolGeneration,
                region: info.region,
                warmup: warmup,
                activeDuration: activeDuration
            )

            onStage(.startingSession)
            // Returned un-started: the manager installs its handlers first, so
            // the very first record cannot be delivered into a nil handler.
            let monitor = SibionicsSensorMonitor(session: session, warmup: warmup, activatedAt: activatedAt)
            return Outcome(
                monitor: monitor, deviceInfo: deviceInfo,
                activatedAt: activatedAt, didActivate: didActivate,
                serial: reportedSerial
            )
        } catch {
            transport.disconnect()
            throw error
        }
    }

    // MARK: - Device information

    private func readDeviceInfo(transport: SibionicsGATTTransport, mac: String) async throws -> SibionicsDeviceInfo {
        // A missing 0x180A is not fatal: without a software revision the driver
        // assumes V3, which is the only generation it speaks, and the auth frame
        // will fail loudly if that is wrong.
        let software = (try? await transport.read(SibionicsGATT.softwareRevision))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let manufacturer = (try? await transport.read(SibionicsGATT.manufacturerName))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let model = (try? await transport.read(SibionicsGATT.modelNumber))
            .flatMap { String(data: $0, encoding: .utf8) }
        let serial = (try? await transport.read(SibionicsGATT.serialNumber))
            .flatMap { String(data: $0, encoding: .utf8) }

        let version = SibionicsProtocolVersion(
            softwareRevision: software, manufacturer: manufacturer, modelNumber: model
        )
        logger.info("device info \(version) model=\(model ?? "nil") serial=\(serial ?? "nil")")
        return SibionicsDeviceInfo(
            mac: mac,
            model: model,
            serial: serial,
            softwareRevision: software,
            protocolGeneration: version.generation,
            region: version.region
        )
    }
}
