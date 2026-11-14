// pattern: Mixed (unavoidable) — presentation reads app state directly.
// Page preview via PDFKit representable; adjacent editable transcription.

import BooxBridgeCore
import PDFKit
import SwiftUI

struct DocumentDetailView: View {
    @Environment(AppEnvironment.self) private var app
    let documentID: Int64

    @State private var pageIndex: Int = 0
    @State private var draftTranscript: String = ""
    @State private var loadedRevision: Int64 = -1
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
        VStack(spacing: 0) {
            HSplitView {
                previewPane(document: document, pages: pages)
                    .frame(minWidth: 300, maxWidth: .infinity)
                transcriptPane(pages: pages, revisionID: revisionID)
                    .frame(minWidth: Metrics.transcriptEditorMinWidth, idealWidth: 420)
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
            OCRConsentSheet(document: document, pages: pages) {
                Task { await app.enqueueOCR(documentID: documentID, pages: nil) }
            }
        }
        .onAppear { loadTranscript(pages: pages, revisionID: revisionID) }
        .onChange(of: revisionID) {
            loadTranscript(pages: app.pages(revisionID: revisionID), revisionID: revisionID)
        }
        .onChange(of: pageIndex) { _, _ in
            if pageIndex >= 0, pageIndex < pages.count {
                draftTranscript = effectiveText(pages[pageIndex])
            }
        }
    }

    private func previewPane(document: DocumentSummary, pages: [PageTranscript]) -> some View {
        VStack(spacing: 0) {
            if document.pageCount == 0 {
                ContentUnavailableView("No pages", systemImage: "doc.badge.ellipsis")
            } else {
                PagePreviewView(environment: app, document: document, pageIndex: pageIndex)
                    .accessibilityLabel("Page \(pageIndex + 1) preview")
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
                    Slider(value: $zoomScale, in: 0.5...3)
                        .frame(width: 160)
                        .accessibilityLabel("Zoom")
                }
                .padding(10)
            }
        }
    }

    private func transcriptPane(pages: [PageTranscript], revisionID: Int64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
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
            TextEditor(text: $draftTranscript)
                .font(TypeStyles.prose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Transcription editor for page \(pageIndex + 1)")
            HStack {
                Spacer()
                Button("Save Edit") {
                    if pageIndex >= 0, pageIndex < pages.count {
                        app.updateTranscript(pageID: pages[pageIndex].id, text: draftTranscript)
                        app.refreshLibrary()
                    }
                }
                .keyboardShortcut("s", modifiers: [.command])
                .accessibilityLabel("Save transcription edit")
            }
        }
        .padding(Metrics.paneHorizontalInset)
    }

    private func loadTranscript(pages: [PageTranscript], revisionID: Int64) {
        guard revisionID != loadedRevision else { return }
        loadedRevision = revisionID
        pageIndex = 0
        draftTranscript = pages.first.map(effectiveText(_:)) ?? ""
    }

    private func effectiveText(_ page: PageTranscript) -> String {
        page.effectiveText.isEmpty ? page.rawTranscription : page.effectiveText
    }

    private func export(document: DocumentSummary, format: TranscriptFormat) {
        guard let text = app.exportText(documentID: document.id, format: format) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .markdown ? [.markdownText] : [.plainText]
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

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                ImageView(image: image)
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

    private struct ImageView: NSViewRepresentable {
        let image: NSImage
        func makeNSView(context: Context) -> NSImageView {
            let view = NSImageView()
            view.imageScaling = .scaleProportionallyUpOrDown
            return view
        }
        func updateNSView(_ view: NSImageView, context: Context) {
            view.image = image
        }
    }
}

/// Explicit OCR disclosure: destination model, page count, and billing note
/// before any request is queued.
struct OCRConsentSheet: View {
    let document: DocumentSummary
    let pages: [PageTranscript]
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transcribe with a vision model").font(TypeStyles.detailTitle)
            if let profile = activeProfile {
                Text("Provider: \(profile.displayName)")
                Text("Model: \(profile.modelID)")
                    .font(TypeStyles.monoDetail)
            } else {
                Text("No provider profile is configured — add one in Settings → Providers.")
            }
            Text("\(pages.count) page(s) will be sent as images to the provider. Requests may bill against your provider account, and the pages leave this Mac.")
                .font(TypeStyles.rowSecondary)
                .foregroundStyle(.secondary)
            Text("Your edits are never overwritten; re-running OCR stores raw text separately.")
                .font(TypeStyles.rowSecondary)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Transcribe \(pages.count) Page(s)") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(activeProfile == nil)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    @Environment(AppEnvironment.self) private var app
    private var activeProfile: ProviderProfile? { app.activeProfile() }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
