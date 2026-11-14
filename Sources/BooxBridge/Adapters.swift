// pattern: Imperative Shell
// macOS platform adapters: Keychain credential storage and PDFKit page
// rendering. Everything platform-specific lives in the app target; the core
// only sees the seams.

import BooxBridgeCore
import PDFKit
import Security
import Foundation

/// API keys live in the Keychain, scoped to this app's service name and the
/// profile id — never in UserDefaults, the catalog, or logs.
struct KeychainCredentialStore: CredentialStoring {
    let service = "dev.booxbridge.app.providerkey"

    func saveSecret(_ secret: String, forProfileID profileID: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus),
                              userInfo: [NSLocalizedDescriptionKey: "Keychain write failed (status \(addStatus))"])
            }
        } else if updateStatus != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain update failed (status \(updateStatus))"])
        }
    }

    func secret(forProfileID profileID: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain read failed (status \(status))"])
        }
        guard let data = item as? Data, let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        return secret
    }

    func deleteSecret(forProfileID profileID: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "Keychain delete failed (status \(status))"])
        }
    }
}

/// Renders PDF/image pages to PNG bytes with bounded dimensions and a white
/// background, caching to the managed preview cache.
final class PDFKitPageRenderer: PageRendering {
    let storage: ManagedStorage
    let pdfCache = PDFDocumentCache()

    init(storage: ManagedStorage) {
        self.storage = storage
    }

    func pngData(revisionSHA256: String, pageIndex: Int, maxDimensionPoints: CGFloat) throws -> Data {
        let original = try storage.originalURL(revisionSHA256: revisionSHA256)
        let cached = storage.previewCacheURL(revisionID: hashToPseudoRevision(revisionSHA256), pageIndex: pageIndex)
        if let data = try? Data(contentsOf: cached) { return data }

        let document = try pdfCache.document(at: original)
        guard pageIndex < document.pageCount else {
            throw PageRenderError.pageIndexOutOfRange(index: pageIndex, count: document.pageCount)
        }
        guard let page = document.page(at: pageIndex) else {
            throw PageRenderError.renderFailed("PDFKit returned no page for index \(pageIndex)")
        }
        let data = try Self.render(page: page, maxDimension: maxDimensionPoints)
        try? data.write(to: cached)
        return data
    }

    static func render(page: PDFPage, maxDimension: CGFloat) throws -> Data {
        // Crop box wins over the media box (scanner/export artifacts);
        // PDFKit falls back to the media box when no crop box is set.
        // `rotation` is 0/90/180/270 and marks pages stored sideways.
        let bounds = page.bounds(for: .cropBox)
        let rotation = CGFloat(page.rotation)
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else {
            throw PageRenderError.renderFailed("page has empty bounds")
        }
        let rotated = rotation.truncatingRemainder(dividingBy: 180) != 0
        let effectiveW = rotated ? height : width
        let effectiveH = rotated ? width : height
        let scale = min(maxDimension / effectiveW, maxDimension / effectiveH, 4)
        let pixelW = max(1, Int(effectiveW * scale))
        let pixelH = max(1, Int(effectiveH * scale))
        guard pixelW <= Int(DocumentLimits.maxPageDimensionPoints) * 2,
              pixelH <= Int(DocumentLimits.maxPageDimensionPoints) * 2 else {
            throw DocumentValidationError.pageTooLarge(dimension: "\(pixelW)×\(pixelH)")
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: pixelW, height: pixelH, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw PageRenderError.renderFailed("could not create bitmap context")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)) // white behind transparent PDFs
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
        if rotated {
            ctx.translateBy(x: bounds.midX, y: bounds.midY)
            ctx.rotate(by: rotation * .pi / 180)
            ctx.translateBy(x: -bounds.midX, y: -bounds.midY)
        }
        page.draw(with: .cropBox, to: ctx)

        guard let image = ctx.makeImage(),
              let rep = NSBitmapImageRep(cgImage: image),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw PageRenderError.renderFailed("PNG encoding failed")
        }
        return png
    }

    private func hashToPseudoRevision(_ sha: String) -> Int64 {
        // Preview cache keys are per revision-hash; a stable 63-bit fold of
        // the hex string keeps cache filenames deterministic and unique.
        var value: UInt64 = 0
        for byte in sha.utf8.prefix(16) {
            value = value &* 31 &+ UInt64(byte)
        }
        return Int64(value % UInt64(Int32.max))
    }
}

/// Caches open PDFDocuments by URL so page navigation doesn't re-parse the
/// file for every page render.
final class PDFDocumentCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: PDFDocument] = [:]

    func document(at url: URL) throws -> PDFDocument {
        lock.lock()
        if let cached = cache[url.path] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let document = PDFDocument(url: url) else {
            throw DocumentValidationError.unreadable(kind: .pdf)
        }
        if document.isLocked || document.isEncrypted {
            throw DocumentValidationError.encrypted
        }
        guard document.pageCount <= DocumentLimits.maxPageCount else {
            throw DocumentValidationError.tooManyPages(pages: document.pageCount, limit: DocumentLimits.maxPageCount)
        }
        lock.lock()
        cache[url.path] = document
        lock.unlock()
        return document
    }
}

/// PDFKit-backed validator for imports on macOS.
struct PDFKitDocumentValidator: DocumentValidating {
    let storage: ManagedStorage
    let renderer: PDFKitPageRenderer

    init(storage: ManagedStorage) {
        self.storage = storage
        self.renderer = PDFKitPageRenderer(storage: storage)
    }

    func validate(fileAt url: URL) throws -> DocumentValidation {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= DocumentLimits.maxFileBytes else {
            throw DocumentValidationError.tooLarge(bytes: size, limit: DocumentLimits.maxFileBytes)
        }
        let head = (try FileHandle(forReadingFrom: url).read(upToCount: 512)) ?? Data()
        switch DocumentSniffer.kind(of: head) {
        case .pdf:
            let document = try PDFKitPageRenderer(storage: storage).pdfCache.document(at: url)
            return DocumentValidation(kind: .pdf, pageCount: document.pageCount)
        case .png, .jpeg:
            return DocumentValidation(kind: DocumentSniffer.kind(of: head), pageCount: 1)
        case .unsupported:
            throw DocumentValidationError.unsupportedFormat(detail: "file is not a PDF, PNG, or JPEG")
        }
    }
}

enum AppPaths {
    static func applicationSupport(creating: Bool = true) throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let root = base.appendingPathComponent("Boox Bridge", isDirectory: true)
        if creating {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static var defaults: UserDefaults { .standard }
}
