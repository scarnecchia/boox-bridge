// pattern: Mixed (unavoidable) — presentation reads app state directly.
// Read-only browsing within chosen shared-storage roots; downloads, folder
// creation, and uploads happen ONLY on explicit action.

import BooxBridgeCore
import SwiftUI

struct DeviceFilesView: View {
    @Environment(AppEnvironment.self) private var app

    @State private var path: RemotePath?
    @State private var entries: [RemoteEntry] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var selected: Set<String> = []
    @State private var newFolderName = ""
    @State private var showNewFolder = false

    var body: some View {
        Group {
            if let root = browseRoot {
                browser(root: root)
            } else {
                noRootConfigured
            }
        }
        .navigationTitle("Device Files")
    }

    private var browseRoot: RemotePath? {
        app.importRoots.first?.remoteRoot
    }

    private var noRootConfigured: some View {
        ContentUnavailableView {
            Label("No device folder chosen", systemImage: "externaldrive.badge.questionmark")
        } description: {
            Text(app.devicePhase == .connected(app.selectedSerial ?? "", model: "")
                ? "Choose the Boox export folder in Settings → Device Import to browse files."
                : "Connect the Boox over USB, then choose an export folder in Settings → Device Import.")
        }
    }

    private func browser(root: RemotePath) -> some View {
        VStack(spacing: 0) {
            if loading {
                ProgressView("Listing \(path?.raw ?? root.raw)…")
                    .padding()
            } else if let errorText {
                ContentUnavailableView("Could not list the device",
                                       systemImage: "exclamationmark.triangle",
                                       description: Text(errorText))
                Button("Try Again") { Task { await reload(root: root) } }
            } else {
                table(root: root)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await downloadSelected(root: root) }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .disabled(selected.isEmpty)
                .accessibilityLabel("Download selected files")
                Button { showNewFolder = true } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .accessibilityLabel("Create folder on device")
                Button {
                    uploadFile(root: root)
                } label: {
                    Label("Upload", systemImage: "arrow.up.circle")
                }
                .accessibilityLabel("Upload file to device")
            }
        }
        .alert("New Folder", isPresented: $showNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") { Task { await createFolder(root: root) } }
            Button("Cancel", role: .cancel) {}
        }
        .task(id: path?.raw) { await reload(root: root) }
    }

    private func table(root: RemotePath) -> some View {
        let directory = path ?? root
        return List(selection: $selected) {
            if let parent = directory.parent, parent.isWithin(root) || parent == root {
                Button {
                    path = parent == root ? nil : parent
                    selected = []
                } label: {
                    Label("…", systemImage: "arrow.up.folder")
                }
                .accessibilityLabel("Go to parent folder")
            }
            ForEach(entries) { entry in
                row(entry, root: root)
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("Empty folder", systemImage: "folder")
            }
        }
    }

    private func row(_ entry: RemoteEntry, root: RemotePath) -> some View {
        Group {
            if entry.isDirectory {
                Button {
                    path = entry.path
                    selected = []
                } label: {
                    Label(entry.name, systemImage: "folder.fill")
                        .font(TypeStyles.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .buttonStyle(.plain)
            } else {
                HStack {
                    Image(systemName: "doc")
                        .foregroundStyle(Color.accentColor)
                    Text(entry.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(ByteCountFormatter.string(fromByteCount: entry.sizeBytes, countStyle: .file))
                        .font(TypeStyles.monoDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .tag(entry.path.raw)
    }

    // MARK: - Actions

    private func reload(root: RemotePath) async {
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let service = try app.fileService(browseRoot: root)
            entries = try await service.entries(in: path ?? root)
        } catch {
            errorText = String(describing: error)
            entries = []
        }
    }

    private func downloadSelected(root: RemotePath) async {
        let files = selected.compactMap { raw in try? RemotePath(raw) }
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose where to download \(files.count) file(s)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let existing = files.filter { FileManager.default.fileExists(atPath: destination.appendingPathComponent($0.lastComponent).path) }
        let overwrite: Bool
        if existing.isEmpty {
            overwrite = false
        } else {
            let alert = NSAlert()
            alert.messageText = "Replace \(existing.count) existing file(s)?"
            alert.informativeText = existing.map(\.lastComponent).joined(separator: ", ")
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            overwrite = alert.runModal() == .alertFirstButtonReturn
            if !overwrite { return }
        }

        do {
            let service = try app.fileService(browseRoot: root)
            let written = try await service.download(files: files, intoLocalDirectory: destination, overwrite: overwrite)
            app.appendActivity(title: "Downloaded \(written.count) file(s)", detail: destination.path)
        } catch {
            app.appendActivity(title: "Download failed", detail: String(describing: error))
        }
    }

    private func uploadFile(root: RemotePath) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let directory = path ?? root
        Task {
            do {
                let service = try app.fileService(browseRoot: root)
                try await service.upload(localFile: url, toDirectory: directory, overwrite: false)
                app.appendActivity(title: "Uploaded \(url.lastPathComponent)", detail: directory.raw)
                await reload(root: root)
            } catch DeviceFileError.destinationExistsNeedsConfirmation(let message) {
                app.appendActivity(title: "Upload needs your action", detail: message)
            } catch {
                app.appendActivity(title: "Upload failed", detail: String(describing: error))
            }
        }
    }

    private func createFolder(root: RemotePath) async {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        newFolderName = ""
        do {
            let service = try app.fileService(browseRoot: root)
            try await service.createFolder(named: name, in: path ?? root)
            await reload(root: root)
        } catch {
            app.appendActivity(title: "New folder failed", detail: String(describing: error))
        }
    }
}
