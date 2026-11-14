// pattern: Functional Core

import Foundation

public enum TranscriptFormat: String, Sendable {
    case plainText = "txt"
    case markdown = "md"
}

public struct TranscriptExporter {
    public init() {}

    public func export(
        title: String,
        pages: [PageTranscript],
        format: TranscriptFormat,
        pageLabel: (Int) -> String = { "Page \($0 + 1)" }
    ) -> String {
        switch format {
        case .plainText:
            var lines: [String] = [title, String(repeating: "=", count: max(title.count, 3)), ""]
            for page in pages {
                lines.append("── \(pageLabel(page.pageIndex)) ──")
                lines.append(effectiveText(of: page))
                lines.append("")
            }
            return lines.joined(separator: "\n")
        case .markdown:
            var lines: [String] = ["# \(title)", ""]
            for page in pages {
                lines.append("## \(pageLabel(page.pageIndex))")
                lines.append("")
                lines.append(effectiveText(of: page))
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Export publishes a page's persisted effective text. Once the user
    /// has edited the page, that choice is final — including the choice to
    /// clear the text, which must export as empty instead of resurrecting
    /// the raw OCR. Only a never-edited page falls back to the raw
    /// transcription (its effective text still mirrors the OCR output at
    /// that point, so the fallback only covers pages awaiting an edit).
    func effectiveText(of page: PageTranscript) -> String {
        if page.lastEditedAt != nil { return page.effectiveText }
        if !page.effectiveText.isEmpty { return page.effectiveText }
        return page.rawTranscription
    }
}
