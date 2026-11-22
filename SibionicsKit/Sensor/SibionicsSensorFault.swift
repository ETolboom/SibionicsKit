import Foundation

public struct SibionicsSensorFault: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Client-side verdict: the raw electrode current stayed under the
        /// plausibility floor for a full streak. The sensor keeps reporting a
        /// plausible-looking glucose number while doing this, so it can only be
        /// caught from the data stream. Terminal; persisted; ending the sensor
        /// stays user-confirmed.
        case signalImplausible
        /// The sensor itself reported a failure in its status (`dstate` 3 or 5,
        /// the official app's "Sensor Failed"). Terminal; persisted.
        case sensorReported
    }

    public let kind: Kind
    public let receivedAt: Date
    public let detail: String?

    public var isTerminal: Bool { true }

    public init(kind: Kind, receivedAt: Date = Date(), detail: String? = nil) {
        self.kind = kind
        self.receivedAt = receivedAt
        self.detail = detail
    }
}
