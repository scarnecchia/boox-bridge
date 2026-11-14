// pattern: Functional Core (seam declaration)
// Credential storage seam. Secrets live ONLY behind this protocol — in the
// macOS app that is the Keychain adapter; tests use the in-memory store.
// Nothing in the core ever logs, persists, or error-reports a secret; the
// redaction helper exists for defense in depth at every formatting site.

import Foundation

public protocol CredentialStoring: Sendable {
    func saveSecret(_ secret: String, forProfileID profileID: String) throws
    func secret(forProfileID profileID: String) throws -> String?
    func deleteSecret(forProfileID profileID: String) throws
}

/// Test/scenario-only store. Never used by the macOS app.
public final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    public init() {}

    public func saveSecret(_ secret: String, forProfileID profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        secrets[profileID] = secret
    }

    public func secret(forProfileID profileID: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return secrets[profileID]
    }

    public func deleteSecret(forProfileID profileID: String) throws {
        lock.lock(); defer { lock.unlock() }
        secrets.removeValue(forKey: profileID)
    }
}

public enum CredentialError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingKey(profileID: String)

    public var description: String {
        switch self {
        case .missingKey(let id): return "no API key stored for profile \(id) — add one in Settings"
        }
    }
}
