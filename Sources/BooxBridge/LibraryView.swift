// pattern: Mixed (unavoidable) — presentation reads app state directly.

import BooxBridgeCore
import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var app
    @Binding var selectedDocumentIDs: Set<Int64>

    @State private var showMoveSheet = false
    @State private var pendingMoveIDs: [Int64] = []

    var body: some View {
        Group {
            if !app.searchResults.isEmpty {
                searchResults
            } else if app.documents.isEmpty {
                emptyState
            } else {
                documentList
            }
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem {
                folderPicker
            }
            ToolbarItem {
                if !selectedDocumentIDs.isEmpty {
                    HStack(spacing: Metrics.toolbarActionSpacing) {
                        Button {
                            pendingMoveIDs = sortedSelection()
                            showMoveSheet = true
                        } label: {
                            Label("Move to Folder", systemImage: "folder.badge.gearshape")
                        }
                        .accessibilityLabel("Move selected notes to folder")
                        Button {
                            confirmDelete(sortedSelection())
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .accessibilityLabel("Remove selected notes from library")
                    }
                }
            }
        }
        .sheet(isPresented: $showMoveSheet) {
            MoveToFolderSheet(folders: app.folders, noteCount: pendingMoveIDs.count) { folder in
                app.moveToFolder(pendingMoveIDs, folder: folder)
                selectedDocumentIDs = []
            }
        }
        .onAppear { app.refreshLibrary() }
    }

    private var emptyState: some View {
        VStack(spacing: Metrics.emptyStateStackSpacing) {
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
        }
    }

    private var searchResults: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.searchResultsStackSpacing) {
                Text("Search results").font(TypeStyles.sectionHeader)
                ForEach(app.searchResults) { hit in
                    Button {
                        selectedDocumentIDs = [hit.documentID]
                    } label: {
                        VStack(alignment: .leading, spacing: Metrics.searchHitLineSpacing) {
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

    // Multi-select List: cmd/shift-click selects several notes for the bulk
    // toolbar actions; a single selection drives the detail column (see
    // RootView — selection-driven detail, no NavigationLink pushes).
    private var documentList: some View {
        List(app.documents, selection: $selectedDocumentIDs) { document in
            LibraryRow(document: document)
                .contextMenu {
                    contextActions(for: document)
                }
        }
    }

    private var folderPicker: some View {
        Picker("Folder", selection: Binding(
            get: { app.folderFilter },
            set: { filter in
                app.folderFilter = filter
                selectedDocumentIDs = []
            })) {
            Text(LibraryFolderFilter.all.label).tag(LibraryFolderFilter.all)
            Text(LibraryFolderFilter.unfiled.label).tag(LibraryFolderFilter.unfiled)
            ForEach(app.folders, id: \.self) { name in
                Text(name).tag(LibraryFolderFilter.named(name))
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityLabel("Filter library by folder")
    }

    @ViewBuilder
    private func contextActions(for document: DocumentSummary) -> some View {
        Button("Reveal Original in Finder") { revealOriginal(document) }
        Button("Move to Folder…") {
            pendingMoveIDs = targetIDs(for: document)
            showMoveSheet = true
        }
        Divider()
        Button("Delete from Library…", role: .destructive) {
            confirmDelete(targetIDs(for: document))
        }
    }

    /// Context actions cover the whole selection when the row under the
    /// cursor is part of it, otherwise that row alone.
    private func targetIDs(for document: DocumentSummary) -> [Int64] {
        selectedDocumentIDs.contains(document.id) ? sortedSelection() : [document.id]
    }

    private func sortedSelection() -> [Int64] {
        selectedDocumentIDs.sorted()
    }

    private func revealOriginal(_ document: DocumentSummary) {
        guard let revision = app.revisions(documentID: document.id).last,
              let url = try? app.storage.originalURL(revisionSHA256: revision.contentSHA256) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func confirmDelete(_ ids: [Int64]) {
        // Library-only deletion: originals and revisions are retained, and
        // nothing is ever sent to the device.
        let subject = ids.count == 1
            ? "“\(app.document(id: ids[0])?.title ?? "note")”"
            : "\(ids.count) notes"
        NSApp.requestUserAttention(.criticalRequest)
        let alert = NSAlert()
        alert.messageText = "Remove \(subject) from the library?"
        alert.informativeText = "The original file and its revisions stay on this Mac. Nothing is deleted from the Boox."
        alert.addButton(withTitle: "Remove from Library")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            app.deleteDocuments(ids)
            for id in ids { selectedDocumentIDs.remove(id) }
        }
    }
}

struct LibraryRow: View {
    let document: DocumentSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowLineSpacing) {
            HStack(spacing: Metrics.rowIconTextSpacing) {
                Image(systemName: document.kind == .pdf ? "doc.richtext" : "photo")
                    .foregroundStyle(Color.accentColor)
                Text(document.title)
                    .font(TypeStyles.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Metrics.rowTrailingSpacerMin)
                if !document.folder.isEmpty {
                    Label(document.folder, systemImage: "folder")
                        .font(TypeStyles.monoDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
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

/// Move dialog for one or more notes: pick an existing folder, choose
/// "None (unfiled)", or type a new name. A non-empty name wins over the
/// picker, so creating a folder needs no mode switch.
struct MoveToFolderSheet: View {
    let folders: [String]
    let noteCount: Int
    let onMove: (String) -> Void

    @State private var existingFolder: String?
    @State private var newFolderName = ""
    @Environment(\.dismiss) private var dismiss

    init(folders: [String], noteCount: Int, onMove: @escaping (String) -> Void) {
        self.folders = folders
        self.noteCount = noteCount
        self.onMove = onMove
        _existingFolder = State(initialValue: folders.first)
    }

    /// Empty result means unfiled; it is only reachable via the explicit
    /// picker choice, so a stray click cannot silently unfile notes.
    private var targetFolder: String {
        let typed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? (existingFolder ?? "") : typed
    }

    private var canMove: Bool {
        !newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || existingFolder != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sheetStackSpacing) {
            Text("Move \(noteCount) note\(noteCount == 1 ? "" : "s") to folder")
                .font(TypeStyles.detailTitle)
            Picker("Existing folder", selection: $existingFolder) {
                Text("None (unfiled)").tag(String?.none)
                ForEach(folders, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            TextField("New folder name", text: $newFolderName)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Move") {
                    onMove(targetFolder)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canMove)
            }
        }
        .padding(Metrics.sheetPadding)
        .frame(width: Metrics.sheetWidth)
    }
}
