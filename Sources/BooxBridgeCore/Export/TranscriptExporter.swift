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

    func effectiveText(of page: PageTranscript) -> String {
        if !page.effectiveText.isEmpty { return page.effectiveText }
        return page.rawTranscription
    }
}
