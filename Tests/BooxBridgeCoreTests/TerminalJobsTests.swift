import Foundation
import Testing
@testable import BooxBridgeCore

@Suite struct TerminalJobsTests {
    private func seedDocument(
        _ catalog: CatalogStore, path: String, folder: String, at date: Date
    ) throws -> (documentID: Int64, revisionID: Int64) {
        let outcome = try catalog.commitImport(
            key: DocumentKey(serial: "s", rootID: "r", relativePath: path),
            kind: .pdf, contentSHA256: UUID().uuidString, sizeBytes: 10, pageCount: 1,
            remoteMtime: 1, remoteSize: 10, at: date)
        guard case .newDocument(let documentID, let revisionID) = outcome else {
            Issue.record("seed failed for \(path)")
            return (-1, -1)
        }
        if !folder.isEmpty {
            try catalog.setFolder(documentIDs: [documentID], folder: folder, at: date)
        }
        return (documentID, revisionID)
    }

    private func enqueue(
        _ catalog: CatalogStore, revisionID: Int64, at date: Date, pageIndex: Int = 0
    ) throws -> Int64 {
        guard let id = try catalog.enqueueJob(
            revisionID: revisionID, pageIndex: pageIndex, profileID: "p",
            modelID: "m", promptVersion: 1, at: date) else {
            Issue.record("expected a job id, got deduplicated nil")
            return -1
        }
        return id
    }

    private func date(_ epoch: TimeInterval) -> Date {
        Date(timeIntervalSince1970: epoch)
    }

    /// The discriminator scenario: the retried job has the LOWEST id but the
    /// NEWEST last-update. Update-time ordering must put it first — the old
    /// id-ordered, folder-filtered rebuild got both wrong.
    @Test func terminalJobsIgnoreFoldersOrderNewestFirstAndCap() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)

            // Retried job, unfiled document, LOWEST id, newest outcome.
            let (_, revisionB) = try seedDocument(catalog, path: "b.pdf", folder: "", at: date(10))
            let retriedID = try enqueue(catalog, revisionID: revisionB, at: date(10))
            try catalog.updateJob(id: retriedID, state: .failed, attempts: 1,
                                  lastError: "boom-1", at: date(20))
            // Retry resets the SAME row (attempt counter, error, update time).
            let resetID = try enqueue(catalog, revisionID: revisionB, at: date(30))
            #expect(resetID == retriedID, "a retried job keeps its identity")
            try catalog.updateJob(id: retriedID, state: .failed, attempts: 1,
                                  lastError: "boom-2", at: date(40))

            // Succeeded job in the "Work" folder, older outcome, HIGHER id.
            let (_, revisionA) = try seedDocument(catalog, path: "a.pdf", folder: "Work", at: date(11))
            let successID = try enqueue(catalog, revisionID: revisionA, at: date(11))
            try catalog.updateJob(id: successID, state: .succeeded, attempts: 1,
                                  lastError: nil, at: date(12))

            // Failed job in the "Personal" folder — invisible when the
            // library filter selects "Work"; the store query must not care.
            let (_, revisionC) = try seedDocument(catalog, path: "c.pdf", folder: "Personal", at: date(13))
            let hiddenID = try enqueue(catalog, revisionID: revisionC, at: date(13))
            try catalog.updateJob(id: hiddenID, state: .failed, attempts: 1,
                                  lastError: "auth rejected", at: date(14))

            let all = try catalog.terminalJobs(limit: 50)

            // Newest first BY UPDATE TIME, regardless of id order: the
            // retried job (lowest id, t=40) precedes the Personal failure
            // (t=14) and the success (t=12) — id-desc order would have put
            // it last, outside any small cap.
            #expect(all.map(\.id) == [retriedID, hiddenID, successID],
                    "expected newest-updated first, got \(all.map(\.id))")
            #expect(all[0].lastError == "boom-2", "the retried job surfaces its NEWEST outcome")
            #expect(all[0].state == .failed)

            // Folder-invisible and unfiled documents are all included.
            #expect(all.contains { $0.revisionID == revisionC })
            #expect(all.contains { $0.revisionID == revisionB })

            // The cap is enforced and keeps the newest outcomes.
            let capped = try catalog.terminalJobs(limit: 2)
            #expect(capped.map(\.id) == [retriedID, hiddenID])
        }
    }

    /// Active states are not history; only terminal jobs appear.
    @Test func queuedAndRunningJobsAreNeverTerminalHistory() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let (_, revisionID) = try seedDocument(catalog, path: "a.pdf", folder: "", at: date(1))

            let queuedID = try enqueue(catalog, revisionID: revisionID, at: date(2), pageIndex: 0)
            let runningID = try enqueue(catalog, revisionID: revisionID, at: date(3), pageIndex: 1)
            try catalog.updateJob(id: runningID, state: .running, attempts: 1,
                                  lastError: nil, at: date(4))
            let doneID = try enqueue(catalog, revisionID: revisionID, at: date(5), pageIndex: 2)
            try catalog.updateJob(id: doneID, state: .succeeded, attempts: 1,
                                  lastError: nil, at: date(6))
            let cancelledID = try enqueue(catalog, revisionID: revisionID, at: date(7), pageIndex: 3)
            try catalog.updateJob(id: cancelledID, state: .cancelled, attempts: 1,
                                  lastError: "stopped", at: date(8))

            let jobs = try catalog.terminalJobs(limit: 50)
            #expect(Set(jobs.map(\.id)) == [doneID, cancelledID])
            #expect(!jobs.contains { $0.id == queuedID })
            #expect(!jobs.contains { $0.id == runningID })
        }
    }

    /// Deleted documents and superseded revisions leave the history; the
    /// current revision's job stays.
    @Test func deletedDocumentsAndOldRevisionsDropOutOfHistory() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)

            // A deleted document's terminal failure must not surface.
            let (deletedDoc, deletedRevision) = try seedDocument(catalog, path: "gone.pdf", folder: "", at: date(1))
            let goneID = try enqueue(catalog, revisionID: deletedRevision, at: date(2))
            try catalog.updateJob(id: goneID, state: .failed, attempts: 1,
                                  lastError: "gone", at: date(9))
            try catalog.markDocumentsDeleted([deletedDoc], at: date(10))

            // A superseded revision's terminal job must not surface either.
            let (liveDoc, oldRevision) = try seedDocument(catalog, path: "live.pdf", folder: "", at: date(3))
            let oldJobID = try enqueue(catalog, revisionID: oldRevision, at: date(4))
            try catalog.updateJob(id: oldJobID, state: .succeeded, attempts: 1,
                                  lastError: nil, at: date(5))
            let second = try catalog.commitImport(
                key: DocumentKey(serial: "s", rootID: "r", relativePath: "live.pdf"),
                kind: .pdf, contentSHA256: UUID().uuidString, sizeBytes: 12, pageCount: 1,
                remoteMtime: 2, remoteSize: 12, at: date(6))
            guard case .newRevision(_, let newRevision) = second else {
                Issue.record("expected a new revision"); return
            }
            let currentJobID = try enqueue(catalog, revisionID: newRevision, at: date(7))
            try catalog.updateJob(id: currentJobID, state: .succeeded, attempts: 1,
                                  lastError: nil, at: date(8))

            let jobs = try catalog.terminalJobs(limit: 50)
            #expect(jobs.map(\.id) == [currentJobID],
                    "only the live document's current-revision job remains, got \(jobs.map(\.id))")
            _ = liveDoc
        }
    }

    @Test func equalUpdateTimeTiebreaksOnJobID() throws {
        try withTempDirectory { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let (_, revisionID) = try seedDocument(catalog, path: "a.pdf", folder: "", at: date(1))
            let first = try enqueue(catalog, revisionID: revisionID, at: date(2), pageIndex: 0)
            try catalog.updateJob(id: first, state: .failed, attempts: 1,
                                  lastError: nil, at: date(5))
            let second = try enqueue(catalog, revisionID: revisionID, at: date(3), pageIndex: 1)
            try catalog.updateJob(id: second, state: .succeeded, attempts: 1,
                                  lastError: nil, at: date(5))

            let jobs = try catalog.terminalJobs(limit: 50)
            #expect(jobs.map(\.id) == [second, first],
                    "equal update times must tie-break by id descending")
        }
    }
}
