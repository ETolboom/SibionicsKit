import Foundation

/// The account id is validated by the Rust driver, which encodes it the way
/// the official app does (`cgm_sibionics::protocol::account`). S10: it is the
/// only per-user secret; never log it.
public enum SibionicsAccount {
    public struct InvalidAccountID: Error, CustomStringConvertible {
        public var description: String {
            "An account id is either all digits (at most 18446744073709551615) or any other non-empty text."
        }
    }

    public static func validate(_ id: String) throws {
        guard isValidAccount(account: id) else { throw InvalidAccountID() }
    }
}
