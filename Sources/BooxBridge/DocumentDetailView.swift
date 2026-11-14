// pattern: Mixed (unavoidable) — presentation reads app state directly.
// Page preview via PDFKit representable; adjacent editable transcription.

import BooxBridgeCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// System-declared UTType.markdown arrives with OS 27; the 26.1 floor needs
// this imported declaration so export panels offer the real Markdown type.
extension UTType {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

struct DocumentDetailView: View {
    @Environment(AppEnvironment.self) private var app
    let documentID: Int64

    @State private var pageIndex: Int = 0
    @State private var draftTranscript: String = ""
    /// TranscriptDraftPolicy load state: what the draft was last loaded from,
    /// so a same-revision persisted transcript change (OCR completing) can be
    /// told apart from a local edit.
    @State private var loadedRevisionID: Int64?
    @State private var loadedPageID: Int64?
    @State private var draftBaseline: String = ""
    /// Set when the persisted transcript changed under a dirty draft; the UI
    /// offers an explicit reload instead of discarding either side silently.
    @State private var persistedDiverged = false
    @State private var stalePersistedText: String = ""
    @State private var showOCRDisclosure = false
    @State private var zoomScale: CGFloat = 1.0

    var body: some View {
        Group {
            if let document = app.document(id: documentID) {
                content(document)
            } else {
                ContentUnavailableView("Note unavailable", systemImage: "questionmark.square.dashed")
            }
        }
        .navigationTitle(app.document(id: documentID)?.title ?? "Note")
    }

    private func content(_ document: DocumentSummary) -> some View {
        let pages = app.pages(revisionID: document.currentPageRevisionID)
        let revisionID = document.currentPageRevisionID
        let selectedPage = pages[safe: pageIndex]
        let observation = TranscriptDraftObservation(
            revisionID: revisionID,
            pageID: selectedPage?.id,
            persistedText: TranscriptAuthority.text(for: selectedPage)
        )
        return VStack(spacing: 0) {
            HSplitView {
                previewPane(document: document, pages: pages)
                    .frame(minWidth: Metrics.previewPaneMinWidth, maxWidth: .infinity)
                transcriptPane(pages: pages, revisionID: revisionID)
                    .frame(minWidth: Metrics.transcriptEditorMinWidth,
                           idealWidth: Metrics.transcriptEditorIdealWidth)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    export(document: document, format: .plainText)
                } label: {
                    Label("Export Text", systemImage: "doc.plaintext")
                }
                .accessibilityLabel("Export as plain text")
                Button {
                    export(document: document, format: .markdown)
                } label: {
                    Label("Export Markdown", systemImage: "number.square")
                }
                .accessibilityLabel("Export as Markdown")
                Button {
                    revealOriginal(document)
                } label: {
                    Label("Reveal Original", systemImage: "folder")
                }
                .accessibilityLabel("Reveal original in Finder")
                Button {
                    showOCRDisclosure.toggle()
                } label: {
                    Label("Transcribe", systemImage: "text.viewfinder")
                }
                .accessibilityLabel("Transcribe with vision model")
                .disabled(app.activeProfile() == nil)
            }
        }
        .sheet(isPresented: $showOCRDisclosure) {
            OCRConsentSheet(awaitingCount: app.pagesAwaitingTranscription(documentID: documentID).count,
                            totalCount: pages.count) { includeTranscribed in
                Task {
                    await app.enqueueOCR(documentID: documentID,
                                         pages: includeTranscribed ? Array(0..<max(document.pageCount, 0)) : nil)
                }
            }
        }
        .onChange(of: observation, initial: true) { _, current in
            applyDraftPolicy(for: current)
        }
    }

    private func previewPane(document: DocumentSummary, pages: [PageTranscript]) -> some View {
        VStack(spacing: 0) {
            if document.pageCount == 0 {
                ContentUnavailableView("No pages", systemImage: "doc.badge.ellipsis")
            } else {
                // The viewport is measured OUTSIDE the two-axis ScrollView:
                // the ScrollView never issues a viewport-derived proposal,
                // so the fitted base size (zoom 1.0) must come from this
                // reader rather than from the proposal or the image's
                // intrinsic pixel size.
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical]) {
                        PagePreviewView(environment: app, document: document,
                                        pageIndex: pageIndex, zoomScale: zoomScale,
                                        viewportSize: geo.size)
                            .accessibilityLabel("Page \(pageIndex + 1) preview")
                    }
                }
                HStack {
                    Button {
                        pageIndex = max(0, pageIndex - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous page")
                    .disabled(pageIndex == 0)
                    Text("Page \(pageIndex + 1) of \(document.pageCount)")
                        .font(TypeStyles.rowSecondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Button {
                        pageIndex = min(document.pageCount - 1, pageIndex + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("Next page")
                    .disabled(pageIndex >= document.pageCount - 1)
                    Slider(value: $zoomScale, in: Metrics.zoomRange)
                        .frame(width: Metrics.zoomSliderWidth)
                        .accessibilityLabel("Zoom")
                }
                .padding(Metrics.previewControlPadding)
            }
        }
    }

    private func transcriptPane(pages: [PageTranscript], revisionID: Int64) -> some View {
        VStack(alignment: .leading, spacing: Metrics.editorStackSpacing) {
            HStack {
                Text("Transcription").font(TypeStyles.sectionHeader)
                Spacer()
                if let page = pages[safe: pageIndex] {
                    Text(page.lastEditedAt.map { "edited \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "unedited")
                        .font(TypeStyles.monoDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if persistedDiverged {
                HStack(alignment: .top, spacing: Metrics.editorStackSpacing) {
                    Text("The transcription changed while you were editing — this draft doesn't include the fresh text.")
                        .font(TypeStyles.rowSecondary)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Button("Load Fresh Text") { loadFreshPersistedText() }
                        .accessibilityLabel("Load the fresh persisted transcription, discarding this draft")
                }
            }
            TextEditor(text: $draftTranscript)
                .font(TypeStyles.prose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Transcription editor for page \(pageIndex + 1)")
            HStack {
                Spacer()
                Button("Save Edit") {
                    if pageIndex >= 0, pageIndex < pages.count {
                        app.updateTranscript(pageID: pages[pageIndex].id, text: draftTranscript)
                        // Persisted text now equals the draft: resync the
                        // baseline so the policy sees clean state and the
                        // next OCR update can reload normally.
                        draftBaseline = draftTranscript
                        persistedDiverged = false
                        app.refreshLibrary()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])
                .accessibilityLabel("Save transcription edit")
            }
        }
        .padding(Metrics.paneHorizontalInset)
    }

    /// Applies the pure reload decision. Runs from onChange — outside body
    /// evaluation — so mutating @State here is safe.
    private func applyDraftPolicy(for observation: TranscriptDraftObservation) {
        let policy = TranscriptDraftPolicy(
            loadedRevisionID: loadedRevisionID,
            loadedPageID: loadedPageID,
            baselineText: draftBaseline,
            draftText: draftTranscript
        )
        switch policy.decision(for: observation) {
        case .reload(let text):
            let revisionChanged = observation.revisionID != loadedRevisionID
            loadedRevisionID = observation.revisionID
            loadedPageID = observation.pageID
            draftBaseline = observation.persistedText
            draftTranscript = text
            persistedDiverged = false
            stalePersistedText = ""
            if revisionChanged { pageIndex = 0 }
        case .preserve:
            break
        case .preserveStale(let persisted):
            persistedDiverged = true
            stalePersistedText = persisted
        }
    }

    /// Explicit escape hatch for the stale-draft state: adopt the fresh
    /// persisted text over the user's in-progress draft.
    private func loadFreshPersistedText() {
        draftTranscript = stalePersistedText
        draftBaseline = stalePersistedText
        persistedDiverged = false
        stalePersistedText = ""
    }

    private func export(document: DocumentSummary, format: TranscriptFormat) {
        guard let text = app.exportText(documentID: document.id, format: format) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .markdown ? [.markdown] : [.plainText]
        panel.nameFieldStringValue = document.title.replacingOccurrences(of: "/", with: "-") + "." + format.rawValue
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            app.appendActivity(title: "Exported \(url.lastPathComponent)")
        } catch {
            app.appendActivity(title: "Export failed", detail: String(describing: error))
        }
    }

    private func revealOriginal(_ document: DocumentSummary) {
        guard let revision = app.revisions(documentID: document.id).last,
              let url = try? app.storage.originalURL(revisionSHA256: revision.contentSHA256) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Page preview: renders through the app's PDFKit pipeline into an image
/// view; falls back to an explicit error state for invalid pages.
struct PagePreviewView: View {
    let environment: AppEnvironment
    let document: DocumentSummary
    let pageIndex: Int
    /// Magnification applied to the viewport-fitted base size; 1.0 fits.
    var zoomScale: CGFloat = 1.0
    /// The preview pane's scroll viewport, measured outside the ScrollView.
    let viewportSize: CGSize

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                ImageView(image: image, zoomScale: zoomScale, viewportSize: viewportSize)
            } else {
                ProgressView("Rendering page…")
            }
        }
        .task(id: "\(document.currentPageRevisionID)-\(pageIndex)") {
            image = nil
            if let revision = environment.revisions(documentID: document.id).last {
                do {
                    let data = try environment.renderer.pngData(
                        revisionSHA256: revision.contentSHA256,
                        pageIndex: pageIndex,
                        maxDimensionPoints: Metrics.previewMaxDimension
                    )
                    image = NSImage(data: data)
                } catch {
                    environment.appendActivity(
                        title: "Preview failed",
                        detail: "Page \(pageIndex + 1): \(String(describing: error))"
                    )
                }
            }
        }
    }

    struct ImageView: NSViewRepresentable {
        let image: NSImage
        var zoomScale: CGFloat = 1.0
        /// The scroll viewport the image is fitted into at zoom 1.0.
        let viewportSize: CGSize

        func makeNSView(context: Context) -> NSImageView {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            return view
        }
        func updateNSView(_ view: NSImageView, context: Context) {
            view.image = image
        }
        // The proposal is ignored on purpose: a two-axis ScrollView proposes
        // nothing, and trusting the intrinsic pixel size made zoom 1.0 mean
        // "image pixels", cropping large pages. The authoritative size is
        // the viewport-fitted base times the zoom (zoom 1.0 = fit the pane,
        // 2.0 = twice fitted), so magnified content overflows and scrolls.
        func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
            PreviewSizing.scaledSize(imageSize: nsView.image?.size ?? .zero,
                                     viewport: viewportSize, zoomScale: zoomScale)
        }
    }
}

/// Explicit OCR disclosure: destination model, exact page count, and billing
/// note before any request is queued. Defaults to pages without
/// transcription text, so an updated import never re-bills pages whose
/// content carried over; the toggle opts back into full re-transcription.
struct OCRConsentSheet: View {
    let awaitingCount: Int
    let totalCount: Int
    let onConfirm: (_ includeTranscribed: Bool) -> Void
    @State private var includeTranscribed = false
    @Environment(\.dismiss) private var dismiss

    private var targetCount: Int { includeTranscribed ? totalCount : awaitingCount }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sheetStackSpacing) {
            Text("Transcribe with a vision model").font(TypeStyles.detailTitle)
            if let profile = activeProfile {
                Text("Provider: \(profile.displayName)")
                Text("Model: \(profile.modelID)")
                    .font(TypeStyles.monoDetail)
            } else {
                Text("No provider profile is configured — add one in Settings → Providers.")
            }
            if targetCount == 0 {
                Text("Every page already has transcription text. Enable the option below to re-transcribe.")
                    .font(TypeStyles.rowSecondary)
                    .foregroundStyle(.secondary)
            }
            Text("\(targetCount) page(s) will be sent as images to the provider. Requests may bill against your provider account, and the pages leave this Mac.")
                .font(TypeStyles.rowSecondary)
                .foregroundStyle(.secondary)
            if awaitingCount < totalCount {
                Toggle("Re-transcribe pages that already have text", isOn: $includeTranscribed)
                    .font(TypeStyles.rowSecondary)
            }
            Text("Your edits are never overwritten; re-running OCR stores raw text separately.")
                .font(TypeStyles.rowSecondary)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Transcribe \(targetCount) Page(s)") {
                    onConfirm(includeTranscribed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(activeProfile == nil || targetCount == 0)
            }
        }
        .padding(Metrics.sheetPadding)
        .frame(width: Metrics.sheetWidth)
    }

    @Environment(AppEnvironment.self) private var app
    private var activeProfile: ProviderProfile? { app.activeProfile() }
}

extension TranscriptAuthority {
    /// The authoritative text for a persisted page row (nil page → empty).
    static func text(for page: PageTranscript?) -> String {
        guard let page else { return "" }
        return text(effectiveText: page.effectiveText,
                    rawTranscription: page.rawTranscription,
                    lastEditedAt: page.lastEditedAt)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
