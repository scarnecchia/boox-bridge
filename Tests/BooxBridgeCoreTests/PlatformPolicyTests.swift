import Foundation
import Testing
@testable import BooxBridgeCore

@Suite struct PlatformPolicyTests {

    @Test func minimumOSVersionChecks() {
        #expect(PlatformPolicy.isSupported(OSVersion(major: 26, minor: 1)))
        #expect(PlatformPolicy.isSupported(OSVersion(major: 26, minor: 3)))
        #expect(PlatformPolicy.isSupported(OSVersion(major: 27, minor: 0)))
        #expect(!PlatformPolicy.isSupported(OSVersion(major: 26, minor: 0)))
        #expect(!PlatformPolicy.isSupported(OSVersion(major: 15, minor: 5)))

        #expect(OSVersion(major: 27, minor: 0) > PlatformPolicy.minimumMacOS)

        #expect(PlatformPolicy.parseVersion("26.1") == OSVersion(major: 26, minor: 1))
        #expect(PlatformPolicy.parseVersion("26.1.2") == OSVersion(major: 26, minor: 1))
        #expect(PlatformPolicy.parseVersion("14") == OSVersion(major: 14, minor: 0))
        #expect(PlatformPolicy.parseVersion("abc") == nil)
        #expect(PlatformPolicy.parseVersion("26.-1") == nil)

        if case .supported = PlatformPolicy.checkOperatingSystem("26.1") {} else {
            Issue.record("26.1 should be supported")
        }
        if case .unsupported = PlatformPolicy.checkOperatingSystem("14.3") {} else {
            Issue.record("14.3 should be unsupported")
        }
        #expect(!PlatformPolicy.checkOperatingSystem(nil).isSupported)
        #expect(!PlatformPolicy.checkOperatingSystem("garbage").isSupported)
        #expect(!PlatformPolicy.checkOperatingSystem(nil).userMessage.isEmpty)
    }


    @Test func sqliteFTSAvailability() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute("CREATE VIRTUAL TABLE probe_fts USING fts5(body)")
        try db.execute("INSERT INTO probe_fts(rowid, body) VALUES(1, ?)", bindings: [.text("hello handwritten notes")])
        let rows = try db.query("SELECT body FROM probe_fts WHERE probe_fts MATCH ?", bindings: [.text("\"handwritten\"")])
        #expect(rows.count == 1)
        let version = try db.query("SELECT sqlite_version()")
        if case .text(let v)? = version.first?.first {
            #expect(v.hasPrefix("3."))
        } else {
            Issue.record("expected sqlite version string")
        }
    }


    @Test func corePlatformIsolation() throws {
        // The core target must never import UI/platform frameworks; on Linux
        // that is compile-enforced by unavailability, so the test scans
        // sources to keep the rule true on macOS too.
        let coreRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/BooxBridgeCore", isDirectory: true)
        let forbidden = ["SwiftUI", "PDFKit", "AppKit", "Security", "FoundationXML", "Combine"]
        var scanned = 0
        let enumerator = FileManager.default.enumerator(at: coreRoot, includingPropertiesForKeys: nil)
        while let next = enumerator?.nextObject() as? URL {
            guard next.pathExtension == "swift" else { continue }
            scanned += 1
            let source = try String(contentsOf: next, encoding: .utf8)
            for framework in forbidden where source.contains("import \(framework)\n") || source.contains("import \(framework)\r") {
                Issue.record("BooxBridgeCore file \(next.lastPathComponent) imports \(framework)")
            }
        }
        #expect(scanned > 5, "expected to scan the core sources")
    }


    @Test func ftsQueryEscaping() {
        #expect(FTSQuery.phrase("hello") == "\"hello\"")
        #expect(FTSQuery.phrase("a OR b") == "\"a OR b\"")
        #expect(FTSQuery.phrase("col:title") == "\"col:title\"")
        #expect(FTSQuery.phrase("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(FTSQuery.phrase("  ") == "\"\"")
        #expect(FTSQuery.phrase("NEAR(a b)") == "\"NEAR(a b)\"")
    }

    @Test func ftsSearchRoundTrip() throws {
        // Keep all catalog work INSIDE the temp-dir scope: the helper deletes
        // the directory on return, and an open handle would outlive its file.
        try withTempDirectory { dir in
            let store = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
        let key = DocumentKey(serial: "S", rootID: "r", relativePath: "n.pdf")
        let outcome = try store.commitImport(
            key: key, kind: .pdf, contentSHA256: "aa", sizeBytes: 10, pageCount: 1,
            remoteMtime: 1, remoteSize: 10, at: Date()
        )
        guard case .newDocument(let docID, let revID) = outcome else {
            Issue.record("expected new document"); return
        }
        try store.recordTranscription(revisionID: revID, pageIndex: 0, rawText: "grocery list: oat milk", at: Date())
        let hits = try store.search(matching: "oat milk")
        #expect(hits.count == 1 && hits[0].documentID == docID)

        let pages = try store.pages(revisionID: revID)
        try store.updateEffectiveText(pageID: pages[0].id, text: "edited: espresso beans", at: Date())
            #expect(try store.search(matching: "espresso").count == 1)
            #expect(try store.search(matching: "oat milk").isEmpty)
        }
    }
}
