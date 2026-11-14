// pattern: Functional Core
// Pure decision type binding stored provider credentials to a normalized
// endpoint origin. A Keychain secret is keyed by profile id, not by origin,
// so after an endpoint edit the stored key would otherwise silently travel to
// the new host: the old save guard compared scheme+host only (a port change
// slipped through) and the capability probe fetched the stored key for the
// profile id regardless of the draft endpoint. Decisions here must be
// evaluated BEFORE both "Test Connection" and "Save Profile"; the app layer
// computes the origins via the core's EndpointPolicy.normalizedOrigin so the
// app's binding and the core's redirect guard enforce the same rule. No I/O,
// no imports beyond Foundation.

import Foundation

/// Normalized origin: lowercased scheme, lowercased host (IPv6 brackets
/// stripped), effective port — the scheme's default (https 443, http 80)
/// when the URL omits an explicit one. Two endpoints are the same origin
/// only when all three match.
struct ProviderOrigin: Equatable, Sendable, Hashable {
    let scheme: String
    let host: String
    let port: Int
}

/// What may happen to the stored credential when a draft endpoint is tested
/// or saved.
enum CredentialOriginDecision: Equatable, Sendable {
    /// The stored credential may keep being used: either there is none to
    /// endanger (brand-new or keyless profile) or the draft origin matches
    /// the one the credential was entered for. A freshly typed key overwrites
    /// it in place on the same origin — no origin crossing involved.
    case keepCredential
    /// The origin changed and a new key was supplied: remove the stored
    /// credential first (a removal failure must abort the flow fail-closed),
    /// then store the new key for the new origin.
    case rotateCredential
    /// The origin changed and no new key was supplied: the stored credential
    /// must never be used against the new origin — testing is blocked and
    /// saving removes the credential (a removal failure aborts the save).
    case retireCredentialRequireNewKey
    /// The draft URL yields no normalized origin; nothing may be sent.
    case endpointInvalid

    /// Whether the flow must remove the stored credential before continuing.
    /// A removal failure is a hard error that aborts test/save — never a
    /// swallowed warning.
    var requiresCredentialRemoval: Bool {
        switch self {
        case .keepCredential, .endpointInvalid: return false
        case .rotateCredential, .retireCredentialRequireNewKey: return true
        }
    }
}

/// Key-origin binding for one provider profile. `storedOrigin` is the
/// normalized origin of the profile's SAVED endpoint (nil when the profile is
/// new or its saved URL cannot be normalized); `hasStoredKey` distinguishes a
/// keyless saved profile — no stored secret, nothing to endanger.
struct CredentialOriginPolicy: Equatable, Sendable {
    let storedOrigin: ProviderOrigin?
    let hasStoredKey: Bool

    func decision(draftOrigin: ProviderOrigin?, suppliesNewKey: Bool) -> CredentialOriginDecision {
        guard let draftOrigin else { return .endpointInvalid }
        guard hasStoredKey else { return .keepCredential }
        // A stored key whose saved origin cannot be normalized is treated as
        // changed: it must never be assumed compatible with an unverified
        // origin. With a new key it rotates; without one it must be retired.
        guard let storedOrigin else {
            return suppliesNewKey ? .rotateCredential : .retireCredentialRequireNewKey
        }
        if storedOrigin == draftOrigin { return .keepCredential }
        return suppliesNewKey ? .rotateCredential : .retireCredentialRequireNewKey
    }
}
