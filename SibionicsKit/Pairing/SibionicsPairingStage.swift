import Foundation

/// Progress of a pairing, for the onboarding UI.
public enum SibionicsPairingStage: Sendable, Equatable {
    case discovering
    case connecting
    case readingDeviceInfo
    case authenticating
    case activating
    case confirmingActivation
    case startingSession
}
