// documentRenderingFixtures + documentLimits — real PDFKit/CoreGraphics
// against synthetic, non-personal fixtures on macOS.

import BooxBridgeCore
import PDFKit
import XCTest
@testable import BooxBridge

final class DocumentRenderingTests: XCTestCase {
    func tempPDF(pages: [(w: CGFloat, h: CGFloat, rotation: Int)], write data: inout Data) throws -> URL {
        let document = PDFDocument()
        for (index, spec) in pages.enumerated() {
            let page = PDFPage()
            let bounds = CGRect(x: 0, y: 0, width: spec.w, height: spec.h)
            page.setBounds(bounds, for: .mediaBox)
            page.rotation = spec.rotation
            document.insert(page, at: index)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boox-render-\(UUID().uuidString).pdf")
        guard document.write(to: url) else {
            throw XCTSkip("PDFKit could not write the fixture on this host")
        }
        data = (try? Data(contentsOf: url)) ?? Data()
        return url
    }

    func test_documentRenderingFixtures() throws {
        var data = Data()
        let url = try tempPDF(pages: [(300, 400, 0), (500, 200, 90), (200, 500, 270)], write: &data)
        let storage = try withTempDir { dir in
            try ManagedStorage(rootURL: dir.appendingPathComponent("lib"))
        }
        let renderer = PDFKitPageRenderer(storage: storage)
        let hash = SHA256Hasher().sha256Hex(of: data)
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent("stage-\(hash).pdf")
        try data.write(to: staged)
        _ = try storage.commit(stagedFile: staged, contentSHA256: hash)

        for pageIndex in 0..<3 {
            let png = try renderer.pngData(revisionSHA256: hash, pageIndex: pageIndex, maxDimensionPoints: 500)
            XCTAssertFalse(png.isEmpty)
            // White-background, bounded render: expect a real PNG header.
            XCTAssertEqual(String(data: png.prefix(8), encoding: .ascii), "\u{89}PNG\r\n\u{1a}\n")
        }
        // Page index out of range is explicit, not a crash or blank render.
        XCTAssertThrowsError(try renderer.pngData(revisionSHA256: hash, pageIndex: 99, maxDimensionPoints: 500))
    }

    func test_documentLimits() throws {
        // A PDF exceeding the page-count limit is rejected at validation.
        let document = PDFDocument()
        for index in 0..<(DocumentLimits.maxPageCount + 5) {
            let page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 100, height: 100), for: .mediaBox)
            document.insert(page, at: index)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("boox-huge-\(UUID().uuidString).pdf")
        guard document.write(to: url) else {
            throw XCTSkip("PDFKit could not write the large fixture on this host")
        }
        let storage = try withTempDir { dir in
            try ManagedStorage(rootURL: dir.appendingPathComponent("lib"))
        }
        let validator = PDFKitDocumentValidator(storage: storage)
        XCTAssertThrowsError(try validator.validate(fileAt: url)) { error in
            guard case DocumentValidationError.tooManyPages = error else {
                return XCTFail("expected tooManyPages, got \(error)")
            }
        }

        // Garbage that smells like a PDF header is still validated by PDFKit.
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("garbage-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7 definitely not a real document".utf8).write(to: garbage)
        XCTAssertThrowsError(try validator.validate(fileAt: garbage))
    }

    func withTempDir<T>(_ body: (URL) throws -> T) rethrows -> T {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("boox-render-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }
}
