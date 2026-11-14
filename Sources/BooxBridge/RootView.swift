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
    @State private var selectedDocumentID: Int64?

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
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
        } detail: {
            switch section {
            case .library:
                LibraryView(selectedDocumentID: $selectedDocumentID)
            case .deviceFiles:
                DeviceFilesView()
            case .activity:
                ActivityView()
            }
        }
        .searchable(text: $app.searchText, prompt: "Search notes and transcripts")
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
