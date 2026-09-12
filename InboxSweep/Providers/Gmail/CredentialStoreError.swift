import Foundation
import Security

/// A Keychain result code, kept as a value so it can be compared, named, and shown.
///
/// Wrapped rather than passed around as a bare `OSStatus` because the whole point of this
/// interval's credential work is telling one failure apart from another, and a bare integer in
/// an error case invites exactly the "it didn't work" handling that hid the original bug.
nonisolated struct KeychainStatus: Hashable, Sendable, CustomStringConvertible {

    let rawValue: OSStatus

    init(_ rawValue: OSStatus) { self.rawValue = rawValue }

    /// The symbolic name, for the statuses this app can actually reach.
    ///
    /// Only names the ones that mean something here. Anything else is reported by number, which
    /// is still enough to look up, and is never guessed at.
    var name: String {
        switch rawValue {
        case errSecSuccess: "errSecSuccess"
        case errSecItemNotFound: "errSecItemNotFound"
        case errSecDuplicateItem: "errSecDuplicateItem"
        case errSecMissingEntitlement: "errSecMissingEntitlement"
        case errSecNotAvailable: "errSecNotAvailable"
        case errSecAuthFailed: "errSecAuthFailed"
        case errSecInteractionNotAllowed: "errSecInteractionNotAllowed"
        case errSecInteractionRequired: "errSecInteractionRequired"
        case errSecUserCanceled: "errSecUserCanceled"
        case errSecDecode: "errSecDecode"
        case errSecInvalidData: "errSecInvalidData"
        case errSecParam: "errSecParam"
        default: "OSStatus"
        }
    }

    /// `errSecMissingEntitlement (-34018)`: safe to show, carries no secret.
    var description: String { "\(name) (\(rawValue))" }

    // MARK: - Classification

    /// Whether this status means "this keychain has nothing for us", as opposed to a failure.
    var isNotFound: Bool { rawValue == errSecItemNotFound }

    /// Whether this status means *this process cannot use this keychain at all*.
    ///
    /// The distinction that matters: a sandboxed macOS app signed without an
    /// `application-identifier` or `keychain-access-groups` entitlement gets
    /// `errSecMissingEntitlement` from every data-protection-keychain write. That is not a
    /// failure of the save (it is the wrong keychain for this process) which is why
    /// ``KeychainCredentialStore`` treats it as a reason to try the next one rather than as an
    /// error to report. See `docs/session-restore.md`.
    var isKeychainUnavailable: Bool {
        rawValue == errSecMissingEntitlement || rawValue == errSecNotAvailable
    }

    /// Whether the Keychain refused an item it does have, rather than not having one.
    var isAccessFailure: Bool {
        rawValue == errSecAuthFailed
            || rawValue == errSecInteractionNotAllowed
            || rawValue == errSecInteractionRequired
            || rawValue == errSecUserCanceled
    }

    /// Whether the stored bytes themselves were unusable.
    var isDataFailure: Bool {
        rawValue == errSecDecode || rawValue == errSecInvalidData
    }
}

/// Why a credential store could not do what was asked of it.
///
/// Every case is a *distinguishable* outcome the app behaves differently about, which is the
/// requirement this type exists for: "no stored sign-in" and "the Keychain refused us" look the
/// same to a user staring at a signed-out screen, and telling them apart is the difference
/// between a normal first launch and a bug.
///
/// No case carries a token, a refresh token, or any part of one. The associated values are an
/// `OSStatus` and fixed English; there is nothing here that could put a secret on screen or in
/// a log.
nonisolated enum CredentialStoreError: Error, Equatable {

    /// The Keychain has the item but would not hand it over.
    case accessDenied(KeychainStatus)

    /// Something was stored, but it is not a credential this build can read.
    case malformedStoredData

    /// No keychain this process can use was available to write to.
    case noUsableKeychain(KeychainStatus)

    /// Anything else the Keychain reported.
    case unhandled(KeychainStatus)

    /// A short, secret-free sentence for a diagnostic surface.
    var diagnosticDescription: String {
        switch self {
        case .accessDenied(let status):
            "The Keychain declined access to the saved sign-in (\(status))."
        case .malformedStoredData:
            "The saved sign-in could not be read and has been discarded."
        case .noUsableKeychain(let status):
            "No Keychain this app can write to was available (\(status))."
        case .unhandled(let status):
            "The Keychain reported \(status)."
        }
    }
}
