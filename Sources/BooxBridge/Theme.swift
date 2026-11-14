// pattern: Functional Core (constants only)
// Centralized metrics and type styles. Native semantic SF type with weight
// for emphasis; prose measure is capped for reading comfort; colors are
// semantic and adapt to light/dark automatically.

import SwiftUI

enum Metrics {
    static let paneHorizontalInset: CGFloat = 20
    static let rowSpacing: CGFloat = 10
    // Column minimums must sum below the narrowest supported screen
    // (1024pt): 220 sidebar + 320 content + 240 preview + 240 editor.
    static let sidebarMinWidth: CGFloat = 220
    static let contentColumnMinWidth: CGFloat = 320
    static let contentColumnIdealWidth: CGFloat = 460
    static let contentColumnMaxWidth: CGFloat = 680
    static let detailMaxTextWidth: CGFloat = 680   // readable prose measure
    static let transcriptEditorMinWidth: CGFloat = 240
    static let transcriptEditorIdealWidth: CGFloat = 420
    static let previewPaneMinWidth: CGFloat = 240
    static let previewMaxDimension: CGFloat = 1400
    static let previewControlPadding: CGFloat = 10
    static let zoomSliderWidth: CGFloat = 160
    static let zoomRange: ClosedRange<CGFloat> = 0.5...3.0
    static let editorStackSpacing: CGFloat = 8
    static let sheetStackSpacing: CGFloat = 14
    static let sheetPadding: CGFloat = 20
    static let sheetWidth: CGFloat = 440
    static let activityQueueRowSpacing: CGFloat = 3
    static let activityRowSpacing: CGFloat = 2
}

enum TypeStyles {
    static let rowTitle = Font.system(.body, design: .default).weight(.semibold)
    static let rowSecondary = Font.system(.subheadline).weight(.regular)
    static let sectionHeader = Font.system(.headline)
    static let detailTitle = Font.system(.title2).weight(.bold)
    static let prose = Font.system(.body)
    static let monoDetail = Font.system(.caption, design: .monospaced)
}

extension Color {
    static let secondaryLabelColor = Color.secondary
}
