// pattern: Functional Core
// Pure math for the page preview. The preview lives in a two-axis
// ScrollView, which never issues a viewport-derived size proposal, so
// NSImageView's intrinsic pixel size used to stand in for "zoom 1.0" and
// large pages started up cropped. The fitted base size is therefore derived
// from the actual viewport (measured by a GeometryReader OUTSIDE the
// ScrollView) and the zoom multiplies that base: 1.0 fits the pane, 2.0 is
// twice fitted, so magnified content overflows and scrolls instead of
// cropping. No I/O, no view state.

import Foundation

enum PreviewSizing {
    /// The proportional fit of `imageSize` inside `viewport`: the largest
    /// size with the image's aspect ratio that fits both axes. Zero on any
    /// non-positive input (nothing sensible can be displayed yet).
    static func fittedSize(imageSize: CGSize, viewport: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / imageSize.width,
                        viewport.height / imageSize.height)
        return CGSize(width: imageSize.width * scale,
                      height: imageSize.height * scale)
    }

    /// The displayed size at a zoom level: the viewport-fitted base scaled
    /// by `zoomScale` (1.0 = fitted, 2.0 = twice fitted).
    static func scaledSize(imageSize: CGSize, viewport: CGSize, zoomScale: CGFloat) -> CGSize {
        let base = fittedSize(imageSize: imageSize, viewport: viewport)
        return CGSize(width: base.width * zoomScale,
                      height: base.height * zoomScale)
    }
}
