import AppKit
import SwiftUI
import XCTest
@testable import BooxBridge

@MainActor
final class PreviewSizingTests: XCTestCase {
    func test_pagePreviewImageShrinksBelowItsPixelSize() {
        let image = NSImage(size: NSSize(width: 1050, height: 1400))
        let host = NSHostingController(rootView: PagePreviewView.ImageView(image: image))
        let proposal = CGSize(width: 300, height: 400)

        let fitted = host.sizeThatFits(in: proposal)

        XCTAssertLessThanOrEqual(fitted.width, proposal.width)
        XCTAssertLessThanOrEqual(fitted.height, proposal.height)
    }
}
