import AppKit
import SwiftUI
import XCTest
@testable import BooxBridge

@MainActor
final class PreviewSizingTests: XCTestCase {
    func test_pagePreviewImageShrinksBelowItsPixelSize() {
        let image = NSImage(size: NSSize(width: 1050, height: 1400))
        let host = NSHostingController(rootView: PagePreviewView.ImageView(
            image: image, viewportSize: CGSize(width: 300, height: 400)))
        let proposal = CGSize(width: 300, height: 400)

        let fitted = host.sizeThatFits(in: proposal)

        XCTAssertLessThanOrEqual(fitted.width, proposal.width)
        XCTAssertLessThanOrEqual(fitted.height, proposal.height)
    }

    // MARK: - Viewport-derived base × zoom (pure function)

    private let page = CGSize(width: 1050, height: 1400)
    private let pane = CGSize(width: 300, height: 400)

    /// Zoom 1.0 means FIT THE PANE, not "image pixel size": the base is
    /// derived from the viewport (a two-axis ScrollView never proposes one),
    /// so a large page must report exactly the viewport-fitted size instead
    /// of its intrinsic pixels (which started up cropped).
    func test_zoomOneFitsTheViewportNotThePixelSize() {
        let fitted = PreviewSizing.scaledSize(imageSize: page, viewport: pane, zoomScale: 1.0)
        XCTAssertEqual(fitted.width, 300, accuracy: 0.001)
        XCTAssertEqual(fitted.height, 400, accuracy: 0.001)
    }

    /// The fitted base preserves the page's aspect ratio.
    func test_fittedBasePreservesAspectRatio() {
        let fitted = PreviewSizing.fittedSize(imageSize: page, viewport: pane)
        XCTAssertEqual(fitted.width / fitted.height,
                       page.width / page.height, accuracy: 0.0001)
    }

    /// Zoom is linear on the fitted base: 2.0 = twice fitted, 0.5 = half.
    func test_zoomMultipliesTheFittedBase() {
        let one = PreviewSizing.scaledSize(imageSize: page, viewport: pane, zoomScale: 1.0)
        let two = PreviewSizing.scaledSize(imageSize: page, viewport: pane, zoomScale: 2.0)
        let half = PreviewSizing.scaledSize(imageSize: page, viewport: pane, zoomScale: 0.5)
        XCTAssertEqual(two.width, one.width * 2, accuracy: 0.001)
        XCTAssertEqual(two.height, one.height * 2, accuracy: 0.001)
        XCTAssertEqual(half.width, one.width / 2, accuracy: 0.001)
        XCTAssertEqual(half.height, one.height / 2, accuracy: 0.001)
    }

    /// The original contract, now by construction: at zoom 1.0 the reported
    /// size never exceeds the viewport on either axis, for any page shape.
    func test_fittedNeverExceedsTheViewport() {
        let viewports = [CGSize(width: 240, height: 800),
                         CGSize(width: 1024, height: 300),
                         CGSize(width: 50, height: 50)]
        let pages = [page,
                     CGSize(width: 800, height: 600),   // landscape
                     CGSize(width: 100, height: 100),   // smaller than pane
                     CGSize(width: 1, height: 10_000)]  // extreme aspect
        for viewport in viewports {
            for page in pages {
                let fitted = PreviewSizing.scaledSize(imageSize: page, viewport: viewport, zoomScale: 1.0)
                XCTAssertLessThanOrEqual(fitted.width, viewport.width)
                XCTAssertLessThanOrEqual(fitted.height, viewport.height)
            }
        }
    }

    /// Degenerate inputs report zero rather than dividing by zero or NaN.
    func test_degenerateInputsReportZero() {
        XCTAssertEqual(PreviewSizing.fittedSize(imageSize: .zero, viewport: pane), .zero)
        XCTAssertEqual(PreviewSizing.fittedSize(imageSize: page, viewport: .zero), .zero)
        XCTAssertEqual(
            PreviewSizing.scaledSize(imageSize: page, viewport: .zero, zoomScale: 2), .zero)
    }
}
