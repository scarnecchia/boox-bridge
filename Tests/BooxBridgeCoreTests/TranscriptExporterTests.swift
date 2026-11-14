import Foundation
import Testing
@testable import BooxBridgeCore

// Regression coverage for export authority. A page the user edited is
// exported from its persisted effective text, even when the user cleared
// it. Before the fix, an empty effective text always fell back to the raw
// OCR transcription, so a deliberately emptied page resurrected text the
// user had explicitly deleted.

@Suite struct TranscriptExporterTests {
    /// An intentionally emptied edit (effective text cleared, edited_at
    /// set) must export as empty — never as the raw OCR fallback.
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

    /// A page never edited by the user keeps the fallback to raw OCR while
    /// its effective text is still empty — the export is not blank just
    /// because no edit exists yet.
    @Test func neverEditedPageStillFallsBackToRawOCR() throws {
        let exporter = TranscriptExporter()
        let untouched = PageTranscript(
            id: 1, revisionID: 1, pageIndex: 0,
            rawTranscription: "raw ocr text", effectiveText: "", lastEditedAt: nil
        )
        let text = exporter.export(title: "Note", pages: [untouched], format: .plainText)
        #expect(text.contains("raw ocr text"))
    }

    /// A non-empty edit wins over the raw transcription — the rule the
    /// emptied case extends, kept explicit here so the authority contract
    /// for edited pages lives in one place.
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
