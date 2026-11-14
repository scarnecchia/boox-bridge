// pattern: Functional Core (seam declaration)
// Page rendering seam. The macOS adapter renders revision pages to PNG via
// PDFKit/CoreGraphics; tests inject deterministic bytes. The runner only
// ever sends these LOCAL bytes — it never fetches provider-supplied URLs.

import Foundation

public protocol PageRendering: Sendable {
    /// PNG bytes for one page of a revision, rendered at a bounded size.
    func pngData(revisionSHA256: String, pageIndex: Int, maxDimensionPoints: CGFloat) throws -> Data
}

public enum PageRenderError: Error, Equatable, Sendable, CustomStringConvertible {
    case missingBlob(String)
    case pageIndexOutOfRange(index: Int, count: Int)
    case renderFailed(String)

    public var description: String {
        switch self {
        case .missingBlob(let h): return "original content missing for \(h)"
        case .pageIndexOutOfRange(let i, let c): return "page \(i) out of range (document has \(c))"
        case .renderFailed(let d): return "page rendering failed: \(d)"
        }
    }
}

/// 1x1 transparent PNG — the synthetic capability probe sends ONLY this,
/// never a page from the user's notes.
public enum SyntheticProbeImage {
    public static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    )!
}
