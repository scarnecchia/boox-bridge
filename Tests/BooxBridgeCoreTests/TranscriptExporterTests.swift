import Foundation
import Testing
@testable import BooxBridgeCore

@Suite struct TranscriptExporterTests {
    @Test func intentionallyEmptiedPageExportsAsEmpty() throws {
        let exporter = TranscriptExporter()
        let cleared = PageTranscript(
            id: 1, revisionID: 1, pageIndex: 0,
            rawTranscription: "raw ocr text", effectiveText: "", lastEditedAt: Date()
        )
        let text = exporter.export(title: "Note", pages: [cleared], format: .plainText)
        #expect(!text.contains("raw ocr text"))

        let markdown = exporter.export(title: "Note", pages: [cleared], format: .markdown)
        #expect(!markdown.contains("raw ocr text"))
    }

    @Test func neverEditedPageStillFallsBackToRawOCR() throws {
        let exporter = TranscriptExporter()
        let untouched = PageTranscript(
            id: 1, revisionID: 1, pageIndex: 0,
            rawTranscription: "raw ocr text", effectiveText: "", lastEditedAt: nil
        )
        let text = exporter.export(title: "Note", pages: [untouched], format: .plainText)
        #expect(text.contains("raw ocr text"))
    }

    @Test func editedPageExportsPersistedTextOverRaw() throws {
        let exporter = TranscriptExporter()
        let edited = PageTranscript(
            id: 1, revisionID: 1, pageIndex: 0,
            rawTranscription: "raw ocr text", effectiveText: "my words", lastEditedAt: Date()
        )
        let text = exporter.export(title: "Note", pages: [edited], format: .plainText)
        #expect(text.contains("my words"))
        #expect(!text.contains("raw ocr text"))
    }
}
