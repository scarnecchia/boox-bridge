import Foundation
import Testing
@testable import BooxBridgeCore

/// Catalog-level behavior for duplicate-import guards, page carry-over,
/// library folders, and bulk deletion.
@Suite struct DuplicateAndFolderTests {
    let key1 = DocumentKey(serial: "s", rootID: "r", relativePath: "one.pdf")
    let key2 = DocumentKey(serial: "s", rootID: "r", relativePath: "two.pdf")

    func commit(_ catalog: CatalogStore, key: DocumentKey, sha: String, pages: Int = 1,
                mtime: Int64 = 1, size: Int64 = 10,
                carry: [PageCarry.Match] = []) throws -> ImportOutcome {
        try catalog.commitImport(key: key, kind: .pdf, contentSHA256: sha, sizeBytes: size,
                                 pageCount: pages, remoteMtime: mtime, remoteSize: size,
                                 at: Date(), carryPageMatches: carry)
    }

    @Test func crossPathDuplicateSkipsNewDocumentAndAliasesThePath() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            guard case .newDocument(let firstID, _) = try commit(catalog, key: key1, sha: "h") else {
                Issue.record("expected first import to create a document")
                return
            }
            let second = try commit(catalog, key: key2, sha: "h", mtime: 5)
            guard case .duplicate(let canonicalID) = second else {
                Issue.record("expected duplicate outcome, got \(second)")
                return
            }
            #expect(canonicalID == firstID)
            #expect(try catalog.listDocuments().count == 1)

            // The alias must feed the planner: same remote metadata means
            // unchanged, so the identical bytes are never re-pulled.
            let snapshots = try catalog.snapshots(forSerial: "s", rootID: "r")
            #expect(snapshots["two.pdf"]?.revisionSHA256 == "h")
            #expect(snapshots["two.pdf"]?.remoteMtime == 5)
            let plan = ImportPlanner.plan(
                listing: [RemoteFileRecord(path: try RemotePath("/sdcard/note/two.pdf"),
                                           sizeBytes: 10, modifiedEpochSeconds: 5, isRegularFile: true)],
                snapshots: snapshots, root: try RemotePath("/sdcard/note"))
            #expect(plan.unchangedCount == 1)
            #expect(plan.pulls.isEmpty)
        }
    }

    @Test func deletedCanonicalDoesNotSwallowNewContent() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            guard case .newDocument(let firstID, _) = try commit(catalog, key: key1, sha: "h") else {
                Issue.record("expected first import to create a document")
                return
            }
            try catalog.markDocumentDeleted(firstID, at: Date())

            // The user removed the entry deliberately; the same content at a
            // new path must become a real document, not resurrect via alias.
            guard case .newDocument = try commit(catalog, key: key2, sha: "h") else {
                Issue.record("expected a new document for content whose canonical entry was deleted")
                return
            }
            #expect(try catalog.listDocuments().count == 1)
        }
    }

    @Test func aliasPathBecomesRealDocumentWhenContentChanges() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            _ = try commit(catalog, key: key1, sha: "h1")
            _ = try commit(catalog, key: key2, sha: "h1")
            #expect(try catalog.listDocuments().count == 1)

            guard case .newDocument = try commit(catalog, key: key2, sha: "h2", mtime: 9) else {
                Issue.record("expected changed content at an aliased path to create a document")
                return
            }
            let snapshots = try catalog.snapshots(forSerial: "s", rootID: "r")
            #expect(snapshots["two.pdf"]?.revisionSHA256 == "h2")
            #expect(try catalog.listDocuments().count == 2)
        }
    }

    @Test func samePathSameContentRestoresDeletedDocumentAsUnchanged() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            guard case .newDocument(let firstID, _) = try commit(catalog, key: key1, sha: "h") else {
                Issue.record("expected first import to create a document")
                return
            }
            try catalog.markDocumentDeleted(firstID, at: Date())

            let again = try commit(catalog, key: key1, sha: "h")
            guard case .unchanged(let restoredID, _) = again else {
                Issue.record("expected unchanged restore, got \(again)")
                return
            }
            #expect(restoredID == firstID)
            #expect(try catalog.listDocuments().count == 1)
        }
    }

    @Test func commitImportCarriesMatchedPageTextIntoNewRevision() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            guard case .newDocument(_, let revision1) = try commit(catalog, key: key1, sha: "h1", pages: 2) else {
                Issue.record("expected first import to create a document")
                return
            }
            try catalog.recordTranscription(revisionID: revision1, pageIndex: 0, rawText: "alpha", at: Date())
            try catalog.recordTranscription(revisionID: revision1, pageIndex: 1, rawText: "beta", at: Date())

            let carry = [PageCarry.Match(newPage: 0, oldPage: 0),
                         PageCarry.Match(newPage: 2, oldPage: 1)]
            guard case .newRevision(_, let revision2) = try commit(catalog, key: key1, sha: "h2",
                                                                   pages: 3, mtime: 2, carry: carry) else {
                Issue.record("expected changed content to create a revision")
                return
            }
            let pages = try catalog.pages(revisionID: revision2)
            #expect(pages.count == 3)
            #expect(pages[0].rawTranscription == "alpha")
            #expect(pages[2].rawTranscription == "beta")
            #expect(pages[1].rawTranscription.isEmpty)
            // Carried text is searchable against the new revision.
            #expect(try catalog.search(matching: "beta").count == 1)
        }
    }

    @Test func folderAssignmentFiltersSearchAndUnfiles() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            guard case .newDocument(let idA, _) = try commit(catalog, key: key1, sha: "ha"),
                  case .newDocument(let idB, _) = try commit(catalog, key: key2, sha: "hb") else {
                Issue.record("expected both imports to create documents")
                return
            }

            try catalog.setFolder(documentIDs: [idA], folder: "  Research  ", at: Date())
            #expect(try catalog.distinctFolders() == ["Research"])
            #expect(try catalog.listDocuments(folder: "Research").map(\.id) == [idA])
            #expect(try catalog.listDocuments(folder: "").map(\.id) == [idB])
            #expect(try catalog.listDocuments().count == 2)
            // Folder names are part of the FTS index.
            #expect(try catalog.search(matching: "Research").map(\.documentID) == [idA])

            try catalog.setFolder(documentIDs: [idA], folder: "", at: Date())
            #expect(try catalog.distinctFolders().isEmpty)
            #expect(try catalog.listDocuments(folder: "").count == 2)
        }
    }

    @Test func bulkDeleteHidesDocumentsAndSearchHits() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            guard case .newDocument(let idA, let revisionA) = try commit(catalog, key: key1, sha: "ha"),
                  case .newDocument(let idB, _) = try commit(catalog, key: key2, sha: "hb") else {
                Issue.record("expected both imports to create documents")
                return
            }
            try catalog.recordTranscription(revisionID: revisionA, pageIndex: 0, rawText: "findme", at: Date())
            #expect(try catalog.search(matching: "findme").count == 1)

            try catalog.markDocumentsDeleted([idA, idB], at: Date())
            #expect(try catalog.listDocuments().isEmpty)
            #expect(try catalog.search(matching: "findme").isEmpty)
            #expect(try catalog.snapshots(forSerial: "s", rootID: "r").isEmpty)
        }
    }
}
