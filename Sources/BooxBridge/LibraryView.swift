// pattern: Mixed (unavoidable) — presentation reads app state directly.

import BooxBridgeCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var app
    @Binding var selectedDocumentID: Int64?

    var body: some View {
        Group {
            if app.documents.isEmpty {
                emptyState
            } else {
                documentList
            }
        }
        .navigationTitle("Library")
        .frame(minWidth: 500, minHeight: 380)
        .onAppear { app.refreshLibrary() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if !app.searchText.isEmpty {
                ContentUnavailableView("No matches",
                                       systemImage: "magnifyingglass",
                                       description: Text("No transcripts match “\(app.searchText)”."))
            } else {
                ContentUnavailableView {
                    Label("No notes yet", systemImage: "books.vertical")
                } description: {
                    Text("Connect the Boox over USB and import from an export folder, or choose File → Import to add PDFs or images.")
                } actions: {
                    Button("Open Settings") { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
                    Button("Sync Now") { Task { await app.syncNow() } }
                        .disabled(app.selectedSerial == nil)
                }
            }
            if !app.searchResults.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Search results").font(TypeStyles.sectionHeader)
                    ForEach(app.searchResults) { hit in
                        Button {
                            selectedDocumentID = hit.documentID
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title).font(TypeStyles.rowTitle)
                                Text(hit.snippet).font(TypeStyles.rowSecondary)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: Metrics.detailMaxTextWidth, alignment: .leading)
                .padding()
            }
        }
    }

    private var documentList: some View {
        List(app.documents, selection: $selectedDocumentID) { document in
            NavigationLink(value: document.id) {
                LibraryRow(document: document)
            }
            .contextMenu {
                Button("Reveal Original in Finder") { revealOriginal(document) }
                Button("Delete from Library…", role: .destructive) { confirmDelete(document) }
            }
        }
        .navigationDestination(for: Int64.self) { id in
            DocumentDetailView(documentID: id)
        }
    }

    private func revealOriginal(_ document: DocumentSummary) {
        guard let revision = app.revisions(documentID: document.id).last,
              let url = try? app.storage.originalURL(revisionSHA256: revision.contentSHA256) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func confirmDelete(_ document: DocumentSummary) {
        // Library-only deletion: originals and revisions are retained, and
        // nothing is ever sent to the device.
        NSApp.requestUserAttention(.criticalRequest)
        let alert = NSAlert()
        alert.messageText = "Remove “\(document.title)” from the library?"
        alert.informativeText = "The original file and its revisions stay on this Mac. Nothing is deleted from the Boox."
        alert.addButton(withTitle: "Remove from Library")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            app.markDeleted(document.id)
        }
    }
}

struct LibraryRow: View {
    let document: DocumentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: document.kind == .pdf ? "doc.richtext" : "photo")
                    .foregroundStyle(Color.accentColor)
                Text(document.title)
                    .font(TypeStyles.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                if document.revisionCount > 1 {
                    Text("\(document.revisionCount) revisions")
                        .font(TypeStyles.monoDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s") · imported \(document.importedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(TypeStyles.rowSecondary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(document.title), \(document.pageCount) pages")
    }
}
