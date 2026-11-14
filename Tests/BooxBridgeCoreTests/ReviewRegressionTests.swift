import Foundation
import Testing
@testable import BooxBridgeCore

@Suite struct ReviewRegressionTests {
    // Regression: `find -exec sh -c … {} +` batches files as positional
    // parameters; a script that only read "$1" emitted ONE record per
    // batch, silently dropping every other file from sync and browsing.
    @Test func listingScriptEndToEndAgainstRealShell() async throws {
        try await withTempDirectoryAsync { dir in
            let names = [
                "plain.pdf",
                "ünï çø∂é \"quoted\".pdf",
                "-leading-hyphen.png",
                "new\nline.jpg",
                "tab\tinside.pdf",
                "it's quoted'.txt",
                "f6.pdf", "f7.pdf", "f8.pdf", "f9.pdf", "f10.pdf",
                "f11.pdf", "f12.pdf", "f13.pdf", "f14.pdf", "f15.pdf",
            ]
            let root = dir.appendingPathComponent("note", isDirectory: true)
            let sub = root.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for (index, name) in names.enumerated() {
                let data = Data("%PDF-1.7 content-\(index)".utf8)
                try data.write(to: (index % 2 == 0 ? root : sub).appendingPathComponent(name))
            }

            let script = "#!/bin/sh\n" + AdbCommandBuilder.listingScript(for: try RemotePath(root.path)) + "\n"
            let scriptURL = dir.appendingPathComponent("run-listing.sh")
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let runner = FoundationProcessRunner()
            let result = try await runner.run(ProcessRequest(
                executable: scriptURL, arguments: [], timeout: 30
            ))
            #expect(result.succeeded)

            let rootPath = try RemotePath(root.path)
            let records = try RemoteListingParser.parse(result.stdout, root: rootPath)
            #expect(records.count == names.count,
                    "expected \(names.count) records, got \(records.count): \(records.map(\.path.lastComponent))")
            let listed = Set(records.map(\.path.lastComponent))
            for name in names {
                #expect(listed.contains(name), "missing listing record for \(name.debugDescription)")
            }
            #expect(records.allSatisfy { $0.isRegularFile })
        }
    }

    // Regression: unchanged content with a changed mtime must refresh the
    // stored device metadata — otherwise every sync re-pulls the file.
    @Test func unchangedReimportRefreshesRemoteMetadata() async throws {
        try await withTempDirectoryAsync { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let key = DocumentKey(serial: "s", rootID: "r", relativePath: "a.pdf")
            _ = try catalog.commitImport(key: key, kind: .pdf, contentSHA256: "h1",
                                         sizeBytes: 10, pageCount: 1, remoteMtime: 100, remoteSize: 10, at: Date())
            _ = try catalog.commitImport(key: key, kind: .pdf, contentSHA256: "h1",
                                         sizeBytes: 10, pageCount: 1, remoteMtime: 300, remoteSize: 10, at: Date())
            let snapshots = try catalog.snapshots(forSerial: "s", rootID: "r")
            #expect(snapshots["a.pdf"]?.remoteMtime == 300,
                    "snapshot must reflect refreshed mtime or unchanged files re-pull forever")
            let record = RemoteFileRecord(path: try RemotePath("/r/a.pdf"), sizeBytes: 10,
                                          modifiedEpochSeconds: 300, isRegularFile: true)
            let plan = ImportPlanner.plan(listing: [record], snapshots: snapshots,
                                          root: try RemotePath("/r"))
            #expect(plan.unchangedCount == 1)
            #expect(plan.pulls.isEmpty)
        }
    }

    // Regression: re-importing a locally deleted document must restore it,
    // not collide with the UNIQUE constraint.
    @Test func reimportRestoresLocallyDeletedDocument() async throws {
        try await withTempDirectoryAsync { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let key = DocumentKey(serial: "s", rootID: "r", relativePath: "a.pdf")
            let first = try catalog.commitImport(key: key, kind: .pdf, contentSHA256: "h1",
                                                 sizeBytes: 10, pageCount: 1, remoteMtime: 1, remoteSize: 10, at: Date())
            guard case .newDocument(let documentID, _) = first else {
                Issue.record("seed failed"); return
            }
            try catalog.markDocumentDeleted(documentID, at: Date())
            #expect(try catalog.listDocuments().isEmpty)

            let second = try catalog.commitImport(key: key, kind: .pdf, contentSHA256: "h1",
                                                  sizeBytes: 10, pageCount: 1, remoteMtime: 2, remoteSize: 10, at: Date())
            guard case .unchanged(let restoredID, _) = second else {
                Issue.record("expected unchanged after restore, got \(second)"); return
            }
            #expect(restoredID == documentID)
            #expect(try catalog.listDocuments().count == 1)

            try catalog.markDocumentDeleted(documentID, at: Date())
            let third = try catalog.commitImport(key: key, kind: .pdf, contentSHA256: "h2",
                                                 sizeBytes: 12, pageCount: 1, remoteMtime: 3, remoteSize: 12, at: Date())
            guard case .newRevision(let doc3, _) = third else {
                Issue.record("expected newRevision, got \(third)"); return
            }
            #expect(doc3 == documentID)
            #expect(try catalog.listDocuments().count == 1)
            #expect(try catalog.revisions(documentID: documentID).count == 2)
        }
    }
}
