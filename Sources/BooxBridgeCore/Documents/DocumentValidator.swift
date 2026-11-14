// pattern: Functional Core (sniffer + limits) / Imperative Shell (seam)
// Document format policy: magic-byte sniffing and bounded-size rules are
// pure; actual page counting/rendering is platform work behind the
// DocumentValidating seam (PDFKit adapter lives in the macOS app target).

import Foundation

public enum DocumentLimits {
    public static let maxFileBytes: Int64 = 512 * 1024 * 1024
    public static let maxPageCount = 2_000
    public static let maxPageDimensionPoints: CGFloat = 20_000
    public static let supportedExtensions: Set<String> = ["pdf", "png", "jpg", "jpeg"]
}

public enum DocumentSniffer {
    /// Identify a document from its leading bytes. `%PDF-`, PNG signature,
    /// JPEG SOI+marker. Returns .unsupported for anything else — including
    /// `.note` files, which surface explicitly, never as fake PDFs.
    public static func kind(of data: Data) -> DocumentKind {
        if data.count >= 5, data.prefix(5) == Data("%PDF-".utf8) { return .pdf }
        if data.count >= 8, data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if data.count >= 3, data.prefix(3) == Data([0xFF, 0xD8, 0xFF]) { return .jpeg }
        return .unsupported
    }

    public static func kind(forExtension ext: String) -> DocumentKind {
        switch ext.lowercased() {
        case "pdf": return .pdf
        case "png": return .png
        case "jpg", "jpeg": return .jpeg
        default: return .unsupported
        }
    }

    /// Unsupported extensions that are common on Boox devices; named so the
    /// UI can explain them instead of showing a generic failure.
    public static let knownUnsupportedExtensions: Set<String> = ["note", "dsn", "obj", "link", "scr"]
}

public struct DocumentValidation: Equatable, Sendable {
    public let kind: DocumentKind
    public let pageCount: Int
    /// True for password-protected/encrypted PDFs (detection is best effort
    /// at sniff time; adapters confirm).
    public let isEncrypted: Bool

    public init(kind: DocumentKind, pageCount: Int, isEncrypted: Bool = false) {
        self.kind = kind
        self.pageCount = pageCount
        self.isEncrypted = isEncrypted
    }
}

public enum DocumentValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable(kind: DocumentKind)
    case encrypted
    case tooLarge(bytes: Int64, limit: Int64)
    case tooManyPages(pages: Int, limit: Int)
    case pageTooLarge(dimension: String)
    case unsupportedFormat(detail: String)

    public var description: String {
        switch self {
        case .unreadable(let kind): return "file is not a readable \(kind.rawValue.uppercased())"
        case .encrypted: return "password-protected documents are not supported"
        case .tooLarge(let bytes, let limit): return "document is \(bytes) bytes; limit is \(limit)"
        case .tooManyPages(let pages, let limit): return "document has \(pages) pages; limit is \(limit)"
        case .pageTooLarge(let dim): return "page \(dim) exceeds the maximum renderable dimension"
        case .unsupportedFormat(let detail): return "unsupported document format: \(detail)"
        }
    }
}

/// Platform seam: count pages, confirm readability, and enforce limits.
public protocol DocumentValidating: Sendable {
    func validate(fileAt url: URL) throws -> DocumentValidation
}

/// Pure fallback validator for hosts/tests without PDFKit: trusts the
/// magic bytes, enforces size limits, and reports a single page for images.
public struct SniffingValidator: DocumentValidating {
    public init() {}

    public func validate(fileAt url: URL) throws -> DocumentValidation {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= DocumentLimits.maxFileBytes else {
            throw DocumentValidationError.tooLarge(bytes: size, limit: DocumentLimits.maxFileBytes)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = (try handle.read(upToCount: 512)) ?? Data()
        let kind = DocumentSniffer.kind(of: head)
        guard kind != .unsupported else {
            throw DocumentValidationError.unreadable(kind: .unsupported)
        }
        return DocumentValidation(kind: kind, pageCount: 1)
    }
}
