import CoreBluetooth
import Foundation

/// The narrow BLE surface the protocol layer needs. Keeping it this small is
/// what lets the frame/session code be tested against a fake without
/// CoreBluetooth.
public protocol SibionicsGATTTransport: AnyObject, Sendable {
    var peripheralID: UUID { get }
    /// Best-effort advertised name, for display only.
    var name: String? { get }

    func read(_ characteristic: CBUUID) async throws -> Data
    func write(_ data: Data, to characteristic: CBUUID, withResponse: Bool) async throws
    /// Subscribes to `characteristic` and returns its stream **only once the
    /// peripheral has acknowledged the CCCD write**.
    ///
    /// `setNotifyValue(_:for:)` is asynchronous, and a reply that arrives before
    /// iOS has notifications live is silently discarded. Making this a call that
    /// completes afterwards is what stops a caller from transmitting into that
    /// window — which is exactly what happened once.
    func subscribe(_ characteristic: CBUUID) async throws -> AsyncStream<Data>
    func disconnect()
}

public extension SibionicsGATTTransport {
    var name: String? { nil }
}
