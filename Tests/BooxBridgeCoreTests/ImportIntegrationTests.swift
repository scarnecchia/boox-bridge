// usbReconnectImportIntegration, incrementalImportIntegration,
// changingExportIntegration, catalogRecoveryIntegration — the durable
// import pipeline over the fake transport with real SQLite + storage.
import Foundation
import Testing
@testable import BooxBridgeCore

@Suite struct ImportIntegrationTests {
    func makePDF(_ pages: Int = 2, salt: String = "a") -> Data {
        // Minimal valid PDF header with a marker; the SniffingValidator only
        // checks magic + size. Distinct salts => distinct content hashes.
        Data("%PDF-1.7\n%\(salt)-\(pages)\n%%EOF".utf8)
    }

    func makeService(transport: FakeDeviceTransport, directory: URL) throws -> DeviceImportService {
        let catalog = try CatalogStore.open(atPath: directory.appendingPathComponent("catalog.sqlite").path)
        let storage = try ManagedStorage(rootURL: directory.appendingPathComponent("library", isDirectory: true))
        return DeviceImportService(
            transport: transport, catalog: catalog, storage: storage,
            hasher: SHA256Hasher(), validator: SniffingValidator(),
            clock: ManualClock()
        )
    }

    let root = try! RemotePath("/sdcard/note")
    var importRoot: ImportRoot {
        ImportRoot(id: "r1", serial: "78935a57", remoteRoot: root, displayName: "Notes", enrolledAt: Date())
    }

    // -- incrementalImportIntegration --------------------------------------

    @Test func incrementalImportIsIdempotent() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = FakeDeviceTransport()
            transport.seed(try root.appending("test.pdf"), data: makePDF(salt: "one"), mtime: 100)
            let service = try makeService(transport: transport, directory: dir)
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("catalog.sqlite").path)

            let first = try await service.sync(root: importRoot)
            #expect(first.newDocuments == 1)
            #expect(first.unchanged == 0)
            #expect(first.errors.isEmpty)

            // Same listing again: pure no-op, no pulls issued.
            let second = try await service.sync(root: importRoot)
            #expect(second.newDocuments == 0 && second.newRevisions == 0)
            #expect(second.unchanged == 1)
            #expect(transport.pullCalls == 1)

            let documents = try catalog.listDocuments()
            #expect(documents.count == 1)
            #expect(documents[0].pageCount == 1) // sniffing validator counts 1
            #expect(documents[0].kind == .pdf)
            #expect(documents[0].title == "test.pdf")
        }
    }

    @Test func unsupportedNoteFilesSurfaceExplicitly() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = FakeDeviceTransport()
            transport.seed(try root.appending("journal.note"), data: Data("native".utf8), mtime: 100)
            transport.seed(try root.appending("ok.pdf"), data: makePDF(), mtime: 100)
            let service = try makeService(transport: transport, directory: dir)

            let summary = try await service.sync(root: importRoot)
            #expect(summary.newDocuments == 1)
            #expect(summary.unsupported.count == 1)
            #expect(summary.unsupported[0].extensionName == "note")
            #expect(summary.unsupported[0].explainable)
            // The .note file was never pulled.
            #expect(transport.pullCalls == 1)
        }
    }

    // -- changingExportIntegration -----------------------------------------

    @Test func changedContentCreatesRevisionAndPreservesOriginal() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = FakeDeviceTransport()
            let pdfPath = try root.appending("test.pdf")
            transport.seed(pdfPath, data: makePDF(salt: "v1"), mtime: 100)
            let service = try makeService(transport: transport, directory: dir)
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("catalog.sqlite").path)
            let storage = try ManagedStorage(rootURL: dir.appendingPathComponent("library", isDirectory: true))

            _ = try await service.sync(root: importRoot)
            let v1Hash = try catalog.revisions(documentID: (try catalog.listDocuments().first!.id))[0].contentSHA256

            // Device re-exports with new content + new mtime.
            transport.update(pdfPath, data: makePDF(salt: "v2"), mtime: 200)
            let second = try await service.sync(root: importRoot)
            #expect(second.newRevisions == 1)
            #expect(second.newDocuments == 0)

            let doc = try catalog.listDocuments().first!
            let revisions = try catalog.revisions(documentID: doc.id)
            #expect(revisions.count == 2)
            #expect(doc.currentPageRevisionID == revisions.last!.id)
            // Previous original preserved and still addressable.
            #expect(storage.blobExists(contentSHA256: v1Hash))
            #expect(revisions[0].remoteMtime == 100)
            #expect(revisions[1].remoteMtime == 200)

            // Identical content re-exported (mtime-only churn) → hash
            // equality makes it a no-op revision-wise.
            transport.update(pdfPath, data: makePDF(salt: "v2"), mtime: 300)
            let third = try await service.sync(root: importRoot)
            #expect(third.newRevisions == 0)
            #expect(try catalog.revisions(documentID: doc.id).count == 2)
        }
    }

    @Test func unstableFilesAreDeferredNotCommitted() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = FakeDeviceTransport()
            transport.seed(try root.appending("still-exporting.pdf"), data: makePDF(salt: "x"), mtime: 100)
            transport.mutateOnPostStat = true // size changes between pre/post stat
            let service = try makeService(transport: transport, directory: dir)
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("catalog.sqlite").path)

            let summary = try await service.sync(root: importRoot)
            #expect(summary.newDocuments == 0)
            #expect(summary.deferredUnstable.count == 1)
            #expect(try catalog.listDocuments().isEmpty)
        }
    }

    @Test func corruptTransferIsDeferredByHashCheck() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = FakeDeviceTransport()
            transport.seed(try root.appending("corrupt.pdf"), data: makePDF(salt: "c"), mtime: 100)
            transport.corruptRemoteHash = true
            let service = try makeService(transport: transport, directory: dir)

            let summary = try await service.sync(root: importRoot)
            #expect(summary.deferredUnstable.count == 1)
            #expect(summary.newDocuments == 0)
        }
    }

    @Test func invalidFileKeepsPriorRevisionAndReports() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = FakeDeviceTransport()
            let path = try root.appending("broken.pdf")
            transport.seed(path, data: makePDF(salt: "good"), mtime: 100)
            let service = try makeService(transport: transport, directory: dir)
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("catalog.sqlite").path)

            _ = try await service.sync(root: importRoot)
            let doc = try catalog.listDocuments().first!

            // Device replaces the export with garbage that still smells like a PDF.
            transport.update(path, data: Data("%PDF-1.7 but actually garbage".utf8), mtime: 200)
            // SniffingValidator accepts %PDF- prefix; force a validation failure
            // instead with a non-PDF payload:
            transport.update(path, data: Data("definitely not a pdf".utf8), mtime: 200)
            let summary = try await service.sync(root: importRoot)
            #expect(summary.invalidFiles.count == 1)
            #expect(summary.newRevisions == 0)

            // Previous revision intact and still current.
            let after = try catalog.listDocuments().first!
            #expect(after.currentPageRevisionID == doc.currentPageRevisionID)
        }
    }

    // -- usbReconnectImportIntegration --------------------------------------

    @Test func reconnectRescansAndNeverInfersDeletion() async throws {
        try await withTempDirectoryAsync { dir in
            let transport = FakeDeviceTransport()
            transport.seed(try root.appending("a.pdf"), data: makePDF(salt: "a"), mtime: 100)
            let service = try makeService(transport: transport, directory: dir)
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("catalog.sqlite").path)

            _ = try await service.sync(root: importRoot)
            #expect(try catalog.listDocuments().count == 1)

            // Device goes away mid-session: a failed listing errors out and
            // the library is untouched.
            transport.failListing = true
            do {
                _ = try await service.sync(root: importRoot)
                Issue.record("expected listing failure to surface")
            } catch is ImportError {}

            // Reconnect with the file gone from the listing entirely: the
            // catalog keeps the document (no deletion inference) — and a
            // later reappearance imports cleanly.
            transport.failListing = false
            transport.removeAll()
            let afterDrop = try await service.sync(root: importRoot)
            #expect(afterDrop.unchanged == 0 && afterDrop.newDocuments == 0)
            #expect(try catalog.listDocuments().count == 1) // still there

            transport.seed(try root.appending("a.pdf"), data: makePDF(salt: "a"), mtime: 100)
            _ = try await service.sync(root: importRoot)
            #expect(try catalog.listDocuments().count == 1) // same content → unchanged
        }
    }

    // -- catalogRecoveryIntegration ------------------------------------------

    @Test func launchRecoveryCleansOrphanStagingNotBlobs() async throws {
        try await withTempDirectoryAsync { dir in
            let storage = try ManagedStorage(rootURL: dir.appendingPathComponent("library", isDirectory: true))

            // Orphan staging from a crash.
            let orphan = try storage.newStagingDirectory()
            try Data("junk".utf8).write(to: orphan.appendingPathComponent("partial.pdf"))

            // Committed blob.
            let blobSource = dir.appendingPathComponent("real.pdf")
            try makePDF(salt: "real").write(to: blobSource)
            let hash = try SHA256Hasher().sha256Hex(fileAt: blobSource)
            _ = try storage.commit(stagedFile: blobSource, contentSHA256: hash)

            storage.cleanupOrphanStaging()
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(storage.blobExists(contentSHA256: hash))

            // OCR jobs interrupted by restart surface as resumable failures.
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("catalog.sqlite").path)
            let outcome = try catalog.commitImport(
                key: DocumentKey(serial: "s", rootID: "r", relativePath: "a.pdf"),
                kind: .pdf, contentSHA256: hash, sizeBytes: 10, pageCount: 2,
                remoteMtime: 1, remoteSize: 10, at: Date()
            )
            guard case .newDocument(_, let revisionID) = outcome else { fatalError() }
            let jobID = try catalog.enqueueJob(
                revisionID: revisionID, pageIndex: 0, profileID: "p1",
                modelID: "m1", promptVersion: 1, at: Date()
            )
            try catalog.updateJob(id: jobID!, state: .running, attempts: 1, lastError: nil, at: Date())
            let interrupted = try catalog.recoverInterruptedJobs(at: Date())
            #expect(interrupted == 1)
            let job = try catalog.job(id: jobID!)!
            #expect(job.state == .failed)
            #expect(job.lastError == "interrupted by app restart")
            #expect(job.attempts == 1) // not silently restarted
        }
    }

    @Test func queueDeduplicatesRepeatedEnqueues() async throws {
        try await withTempDirectoryAsync { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let outcome = try catalog.commitImport(
                key: DocumentKey(serial: "s", rootID: "r", relativePath: "a.pdf"),
                kind: .pdf, contentSHA256: "h1", sizeBytes: 1, pageCount: 1,
                remoteMtime: 1, remoteSize: 1, at: Date()
            )
            guard case .newDocument(_, let revisionID) = outcome else { fatalError() }
            let first = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p", modelID: "m", promptVersion: 1, at: Date())
            let second = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p", modelID: "m", promptVersion: 1, at: Date())
            #expect(first != nil)
            #expect(second == nil) // duplicate click is a no-op
            // But a DIFFERENT model is a distinct job.
            let third = try catalog.enqueueJob(revisionID: revisionID, pageIndex: 0, profileID: "p", modelID: "m2", promptVersion: 1, at: Date())
            #expect(third != nil)
        }
    }
}
