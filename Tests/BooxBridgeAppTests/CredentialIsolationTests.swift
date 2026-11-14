// credentialIsolationIntegration — REAL Keychain round-trip plus
// catalog/log assertions that secrets never leave the key store.

import BooxBridgeCore
import XCTest
@testable import BooxBridge

final class CredentialIsolationTests: XCTestCase {
    func test_credentialIsolationIntegration() throws {
        let store = KeychainCredentialStore()
        let profileID = "test-profile-\(UUID().uuidString)"
        let secret = "sk-integration-\(UUID().uuidString)"
        defer { try? store.deleteSecret(forProfileID: profileID) }

        // Round-trip through the REAL Keychain.
        try store.saveSecret(secret, forProfileID: profileID)
        XCTAssertEqual(try store.secret(forProfileID: profileID), secret)

        // Update-in-place overwrites, not duplicates.
        try store.saveSecret("sk-rotated", forProfileID: profileID)
        XCTAssertEqual(try store.secret(forProfileID: profileID), "sk-rotated")

        // Delete removes; missing reads are nil, not errors.
        try store.deleteSecret(forProfileID: profileID)
        XCTAssertNil(try store.secret(forProfileID: profileID))

        // Isolation from the catalog: a committed document, job failures,
        // and FTS content never contain the secret.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boox-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
        try store.saveSecret(secret, forProfileID: profileID)
        let outcome = try catalog.commitImport(
            key: DocumentKey(serial: "s", rootID: "r", relativePath: "n.pdf"),
            kind: .pdf, contentSHA256: "h", sizeBytes: 1, pageCount: 1,
            remoteMtime: 1, remoteSize: 1, at: Date()
        )
        guard case .newDocument(_, let revisionID) = outcome else {
            return XCTFail("seed failed")
        }
        // A job that fails with the secret echoed in a response body must
        // still keep it out of the durable error text.
        let reason = Redaction.redact("bad request with \(secret) inside", secrets: [secret])
        try catalog.updateJob(
            id: try XCTUnwrap(catalog.enqueueJob(
                revisionID: revisionID, pageIndex: 0, profileID: profileID,
                modelID: "m", promptVersion: 1, at: Date())),
            state: .failed, attempts: 1, lastError: reason, at: Date()
        )
        let dbData = try Data(contentsOf: dir.appendingPathComponent("c.sqlite"))
        let wal = dir.appendingPathComponent("c.sqlite-wal")
        let all = wal.fileExists()
            ? dbData + (try Data(contentsOf: wal))
            : dbData
        let needle = Data(secret.utf8)
        XCTAssertNil(all.range(of: needle), "secret must never appear in the catalog database")
        XCTAssertEqual(reason, "bad request with \(Redaction.placeholder) inside")

        // UserDefaults must not carry it either.
        let defaultsDump = UserDefaults.standard.dictionaryRepresentation()
        for (_, value) in defaultsDump {
            if case .some(let s) = value as? String {
                XCTAssertFalse(s.contains(secret), "secret leaked into UserDefaults")
            }
        }
    }
}
