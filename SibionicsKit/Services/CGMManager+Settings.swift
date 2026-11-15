import Foundation

public extension SibionicsCGMManager {
    /// Which registration-key constant to present. A sensor activated by a
    /// different Sibionics app build may want a different one, and that is the
    /// second thing to try if the account id is right but auth still fails.
    @MainActor func setRegistrationKey(_ key: Data) {
        guard key.count == 16 else { return }
        var updated = state
        updated.registrationKey = key
        updated.sensors.update { $0.registrationKey = key }
        setState(updated)
        reauthenticateAfterCredentialChange()
    }
}
