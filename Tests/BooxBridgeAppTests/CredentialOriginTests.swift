// pattern: Functional Core (decision-type regression tests)

import XCTest
@testable import BooxBridge

/// Regression tests for the credential key-origin binding.
///
/// Before this change the save guard compared scheme+host only (a port
/// change such as 443→8443 slipped through as "same host") and swallowed
/// deleteSecret failures with `try?`, while "Test Connection" fetched the
/// stored secret by profile id regardless of the draft endpoint — so editing
/// an existing provider's URL to a different HTTPS host and pressing Test
/// sent the stored secret to that host, bypassing the save-time guard. The
/// decisions now run through CredentialOriginPolicy before BOTH test and
/// save, on the same normalized-origin rule the core's EndpointPolicy
/// enforces for redirects.
///
/// `oldSchemeHostRule` below replicates the pre-fix comparison so each test
/// also documents where the new policy diverges from the old rule.
final class CredentialOriginTests: XCTestCase {
    /// The PRE-FIX save guard: `previous.host != new.host || previous.scheme != new.scheme`.
    private func oldSchemeHostRule(stored: ProviderOrigin?, draft: ProviderOrigin?) -> Bool {
        guard let stored, let draft else { return true } // treated as changed
        return stored.scheme != draft.scheme || stored.host != draft.host
    }

    private func origin(_ scheme: String, _ host: String, _ port: Int) -> ProviderOrigin {
        ProviderOrigin(scheme: scheme, host: host, port: port)
    }

    private func policy(stored: ProviderOrigin?, hasKey: Bool) -> CredentialOriginPolicy {
        CredentialOriginPolicy(storedOrigin: stored, hasStoredKey: hasKey)
    }

    // MARK: - Changed host

    func test_changedHostWithoutNewKeyBlocksStoredKeyUse() {
        let stored = origin("https", "api.example.com", 443)
        let draft = origin("https", "api.other.com", 443)
        XCTAssertTrue(oldSchemeHostRule(stored: stored, draft: draft),
                      "sanity: the old rule also saw a host change")
        guard case .retireCredentialRequireNewKey =
                policy(stored: stored, hasKey: true).decision(draftOrigin: draft, suppliesNewKey: false) else {
            return XCTFail("a changed host must never let the stored key travel to the new host")
        }
    }

    func test_changedHostWithNewKeyAllowsRotation() {
        let stored = origin("https", "api.example.com", 443)
        let draft = origin("https", "api.other.com", 443)
        guard case .rotateCredential =
                policy(stored: stored, hasKey: true).decision(draftOrigin: draft, suppliesNewKey: true) else {
            return XCTFail("a changed host with an explicitly supplied new key is allowed")
        }
    }

    // MARK: - Changed port (the hole the old rule missed)

    func test_changedPortWithoutNewKeyIsNeverSameOrigin() {
        let stored = origin("https", "api.example.com", 443)
        let draft = origin("https", "api.example.com", 8443)
        XCTAssertFalse(oldSchemeHostRule(stored: stored, draft: draft),
                       "pre-fix rule: a 443→8443 change looked same-origin — this divergence is the bug")
        guard case .retireCredentialRequireNewKey =
                policy(stored: stored, hasKey: true).decision(draftOrigin: draft, suppliesNewKey: false) else {
            return XCTFail("a port change must be treated as an origin change")
        }
    }

    func test_changedPortWithNewKeyRotates() {
        let stored = origin("https", "api.example.com", 443)
        let draft = origin("https", "api.example.com", 8443)
        guard case .rotateCredential =
                policy(stored: stored, hasKey: true).decision(draftOrigin: draft, suppliesNewKey: true) else {
            return XCTFail("a port change with an explicitly supplied new key is allowed")
        }
    }

    // MARK: - Same origin with explicit default port

    func test_explicitDefaultPortIsTheSameOrigin() {
        let stored = origin("https", "api.example.com", 443)
        let draft = origin("https", "api.example.com", 443) // explicit :443
        XCTAssertFalse(oldSchemeHostRule(stored: stored, draft: draft),
                       "sanity: the old rule kept this working")
        guard case .keepCredential =
                policy(stored: stored, hasKey: true).decision(draftOrigin: draft, suppliesNewKey: false) else {
            return XCTFail("https://host:443 must equal https://host")
        }
    }

    func test_schemeChangeIsAnOriginChange() {
        let stored = origin("https", "api.example.com", 443)
        let draft = origin("http", "api.example.com", 80)
        guard case .retireCredentialRequireNewKey =
                policy(stored: stored, hasKey: true).decision(draftOrigin: draft, suppliesNewKey: false) else {
            return XCTFail("a scheme change must be an origin change")
        }
    }

    // MARK: - Credential removal (fail-closed handling)

    func test_originChangeDecisionsRequireCredentialRemoval() {
        let stored = origin("https", "api.example.com", 443)
        let draft = origin("https", "api.other.com", 443)
        let policy = policy(stored: stored, hasKey: true)
        for decision in [policy.decision(draftOrigin: draft, suppliesNewKey: false),
                         policy.decision(draftOrigin: draft, suppliesNewKey: true)] {
            XCTAssertTrue(decision.requiresCredentialRemoval,
                          "\(decision) must remove the stored credential before continuing")
        }
    }

    func test_sameOriginAndInvalidDecisionsDoNotTouchCredentials() {
        let stored = origin("https", "api.example.com", 443)
        let policy = policy(stored: stored, hasKey: true)
        XCTAssertFalse(policy.decision(draftOrigin: stored, suppliesNewKey: false).requiresCredentialRemoval)
        XCTAssertFalse(policy.decision(draftOrigin: nil, suppliesNewKey: false).requiresCredentialRemoval)
    }

    // MARK: - Keyless and new profiles

    func test_keylessProfileHasNothingToEndanger() {
        let draft = origin("https", "api.other.com", 443)
        guard case .keepCredential =
                policy(stored: origin("https", "api.example.com", 443), hasKey: false)
                    .decision(draftOrigin: draft, suppliesNewKey: false) else {
            return XCTFail("with no stored secret, an endpoint change cannot leak anything")
        }
    }

    func test_invalidDraftOriginBlocksEverything() {
        let policy = policy(stored: origin("https", "api.example.com", 443), hasKey: true)
        guard case .endpointInvalid = policy.decision(draftOrigin: nil, suppliesNewKey: false) else {
            return XCTFail("an unparseable draft origin must block both test and save")
        }
        guard case .endpointInvalid = policy.decision(draftOrigin: nil, suppliesNewKey: true) else {
            return XCTFail("an unparseable draft origin must block even with a typed key")
        }
    }

    func test_unnormalizableStoredOriginIsTreatedAsChanged() {
        let draft = origin("https", "api.example.com", 443)
        guard case .retireCredentialRequireNewKey =
                policy(stored: nil, hasKey: true).decision(draftOrigin: draft, suppliesNewKey: false) else {
            return XCTFail("a stored key with no normalizable origin must not be assumed compatible")
        }
        guard case .rotateCredential =
                policy(stored: nil, hasKey: true).decision(draftOrigin: draft, suppliesNewKey: true) else {
            return XCTFail("a stored key with no normalizable origin rotates when a new key is supplied")
        }
    }
}
