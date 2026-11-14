// pattern: Functional Core (constants only)
// Centralized metrics and type styles. Native semantic SF type with weight
// for emphasis; prose measure is capped for reading comfort; colors are
// semantic and adapt to light/dark automatically.

import SwiftUI

enum Metrics {
    static let paneHorizontalInset: CGFloat = 20
    static let rowSpacing: CGFloat = 10
    static let sidebarMinWidth: CGFloat = 220
    static let detailMaxTextWidth: CGFloat = 680   // readable prose measure
    static let transcriptEditorMinWidth: CGFloat = 320
    static let previewMaxDimension: CGFloat = 1400
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
