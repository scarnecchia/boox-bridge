// pattern: Functional Core
// Pure plans binding CredentialOriginPolicy decisions to the concrete steps
// "Test Connection" and "Save Profile" may take. The round-2 origin policy
// left a hole in the Test path: the changed-origin branch persisted the typed
// key into the SAVED profile's credential slot BEFORE probing, so abandoning
// the draft after a successful test paired the old endpoint with the new key,
// and a swallowed store failure could send the OLD key to the NEW origin.
// These plans encode the agreed contract: Test NEVER mutates stored
// credentials — it probes the draft origin with an ephemeral, explicitly
// supplied key (a freshly typed key sent to the draft endpoint is what the
// button means; mutating the saved pairing is the defect). The policy's
// rotate branch applies at SAVE time only, and every credential write
// failure propagates fail-closed instead of being suppressed. No I/O: the
// view executes the returned steps in order and aborts on the first failure.

import Foundation

/// The result of one read-only look at the stored secret for a profile.
enum StoredCredential: Equatable {
    /// Read succeeded; a non-empty secret is present.
    case present(String)
    /// No secret stored (or the stored value is empty).
    case absent
    /// The store itself failed. The safe answer is "unknown": a Keychain
    /// read failure must never be answered by probing anyway.
    case unreadable(String)
}

/// Why a Test Connection press is refused before any network call.
enum CredentialProbeBlock: Equatable {
    /// The draft URL yields no normalized origin.
    case invalidEndpoint
    /// The origin changed and no new key was typed: the stored key is never
    /// sent to a different origin (round-2 guarantee).
    case changedOriginNeedsNewKey
    /// Nothing to authenticate with: no typed key and no stored secret.
    case noStoredKey
    /// The stored secret could not be read; probing without knowing the key
    /// is not fail-closed.
    case storedKeyUnreadable(String)
}

/// What a Test Connection press may do.
enum CredentialProbePlan: Equatable {
    /// Probe the DRAFT endpoint with this key. For a typed key this is the
    /// ephemeral draft value; for an unchanged origin with no typed key it
    /// is the stored value, used strictly read-only. No plan case carries a
    /// credential write: testing cannot mutate the saved pairing.
    case probe(apiKey: String)
    /// The flow must not reach the network; surface this block instead.
    case blocked(CredentialProbeBlock)

    static func plan(
        decision: CredentialOriginDecision,
        draftKey: String,
        stored: StoredCredential
    ) -> CredentialProbePlan {
        switch decision {
        case .endpointInvalid:
            return .blocked(.invalidEndpoint)
        case .retireCredentialRequireNewKey:
            return .blocked(.changedOriginNeedsNewKey)
        case .rotateCredential:
            // Changed origin + typed key: probe the draft origin with the
            // typed key itself. The stored secret is neither read for this
            // probe nor touched; retirement/replacement happens at save.
            return .probe(apiKey: draftKey)
        case .keepCredential:
            if !draftKey.isEmpty {
                // Same origin: the typed key may be exercised read-only —
                // it targets exactly the origin the stored pairing uses.
                return .probe(apiKey: draftKey)
            }
            switch stored {
            case .present(let key):
                return .probe(apiKey: key)
            case .absent:
                return .blocked(.noStoredKey)
            case .unreadable(let detail):
                return .blocked(.storedKeyUnreadable(detail))
            }
        }
    }
}

/// One ordered step of Save Profile. A step failure aborts the whole save
/// fail-closed — later steps never run.
enum CredentialSaveStep: Equatable {
    /// Remove the stored secret first (origin rotation or retirement).
    /// A removal failure is a hard error that aborts the save.
    case removeStoredSecret
    /// Persist the non-secret profile record.
    case persistProfile
    /// Store the typed key for the (possibly new) origin. A storage failure
    /// propagates: the flow reports failure, keeps the typed key in the
    /// draft, and never claims "Saved".
    case storeDraftKey
}

/// The ordered steps a Save Profile press executes, derived from the same
/// CredentialOriginPolicy decision the test path uses — so the rotate branch
/// (remove stored secret, then store the typed key) applies at SAVE time,
/// never at test time.
struct CredentialSavePlan: Equatable {
    let steps: [CredentialSaveStep]
    /// The retirement branch additionally reports that the stored key was
    /// cleared, so the user knows to enter a new one for the new address.
    let reportsKeyCleared: Bool

    static func plan(
        decision: CredentialOriginDecision,
        suppliesNewKey: Bool
    ) -> CredentialSavePlan {
        switch decision {
        case .endpointInvalid:
            return CredentialSavePlan(steps: [], reportsKeyCleared: false)
        case .rotateCredential:
            return CredentialSavePlan(
                steps: [.removeStoredSecret, .persistProfile, .storeDraftKey],
                reportsKeyCleared: false)
        case .retireCredentialRequireNewKey:
            return CredentialSavePlan(
                steps: [.removeStoredSecret, .persistProfile],
                reportsKeyCleared: true)
        case .keepCredential:
            return CredentialSavePlan(
                steps: suppliesNewKey ? [.persistProfile, .storeDraftKey] : [.persistProfile],
                reportsKeyCleared: false)
        }
    }
}
