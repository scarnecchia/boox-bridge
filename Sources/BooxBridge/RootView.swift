// pattern: Mixed (unavoidable)
// Reason: view composition reads observable state directly; all decisions
// live in AppEnvironment and the core.

import BooxBridgeCore
import SwiftUI

enum AppSection: String, CaseIterable, Identifiable {
    case library
    case deviceFiles
    case activity

    var id: String { rawValue }
    var label: String {
        switch self {
        case .library: return "Library"
        case .deviceFiles: return "Device Files"
        case .activity: return "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .library: return "books.vertical"
        case .deviceFiles: return "externaldrive"
        case .activity: return "clock.arrow.circlepath"
        }
    }
}

struct RootView: View {
    @Environment(AppEnvironment.self) private var app
    @State private var section: AppSection = .library
    @State private var selectedDocumentIDs: Set<Int64> = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $section) {
                Section {
                    ForEach(AppSection.allCases) { item in
                        NavigationLink(value: item) {
                            Label(item.label, systemImage: item.systemImage)
                        }
                        .accessibilityLabel(item.label)
                    }
                }
                if case .connected(let serial, _) = app.devicePhase {
                    Section("Device") {
                        Text(app.devicePhase.guidance)
                            .font(TypeStyles.rowSecondary)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                        Button("Sync Now") {
                            Task { await app.syncNow(serial: serial) }
                        }
                        .accessibilityLabel("Sync Now")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: Metrics.sidebarMinWidth, ideal: 260)
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) {
                DeviceStatusFooter()
            }
        } content: {
            switch section {
            case .library:
                LibraryView(selectedDocumentIDs: $selectedDocumentIDs)
                    .navigationSplitViewColumnWidth(min: Metrics.contentColumnMinWidth,
                                                    ideal: Metrics.contentColumnIdealWidth,
                                                    max: Metrics.contentColumnMaxWidth)
            case .deviceFiles:
                DeviceFilesView()
                    .navigationSplitViewColumnWidth(min: Metrics.contentColumnMinWidth,
                                                    ideal: Metrics.contentColumnIdealWidth,
                                                    max: Metrics.contentColumnMaxWidth)
            case .activity:
                ActivityView()
                    .navigationSplitViewColumnWidth(min: Metrics.contentColumnMinWidth,
                                                    ideal: Metrics.contentColumnIdealWidth,
                                                    max: Metrics.contentColumnMaxWidth)
            }
        } detail: {
            switch section {
            case .library:
                if selectedDocumentIDs.count == 1, let documentID = selectedDocumentIDs.first {
                    DocumentDetailView(documentID: documentID)
                } else if selectedDocumentIDs.count > 1 {
                    ContentUnavailableView("\(selectedDocumentIDs.count) notes selected",
                                           systemImage: "checkmark.circle",
                                           description: Text("Use the toolbar to move or remove them."))
                } else {
                    ContentUnavailableView("Select a note",
                                           systemImage: "doc.text.magnifyingglass")
                }
            case .deviceFiles, .activity:
                // These tools span the content column; the visibility change
                // below hides the detail column for them.
                EmptyView()
            }
        }
        .searchable(text: $app.searchText, prompt: "Search notes and transcripts")
        .onChange(of: section) { _, new in
            columnVisibility = new == .library ? .all : .doubleColumn
        }
        .onReceive(NotificationCenter.default.publisher(for: .booxNavigate)) { note in
            if let raw = note.object as? String, let target = AppSection(rawValue: raw) {
                section = target
            }
        }
    }
}

struct DeviceStatusFooter: View {
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch app.devicePhase {
            case .connected:
                Label(app.devicePhase.guidance, systemImage: "usb.drive.fill")
                    .foregroundStyle(Color.green)
            case .needsADBPath:
                Label(app.devicePhase.guidance, systemImage: "questionmark.drive")
                    .foregroundStyle(Color.orange)
            default:
                Label(app.devicePhase.guidance, systemImage: "usb.drive.slash")
                    .foregroundStyle(Color.secondary)
            }
        }
        .font(TypeStyles.rowSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityLabel("Device status: \(app.devicePhase.guidance)")
    }
}
