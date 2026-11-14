// pattern: Mixed (unavoidable) — presentation reads app state directly.
// Settings: Providers (profiles + keys + synthetic capability test) and
// Device Import (adb path, enrolled roots, auto-import).

import BooxBridgeCore
import SwiftUI

// The AppEnvironment comes from the Settings scene in BooxBridgeApp; the
// child tabs read it with @Environment(AppEnvironment.self).
struct SettingsView: View {
    var body: some View {
        TabView {
            ProviderSettingsTab().tabItem { Label("Providers", systemImage: "key.horizontal") }
            DeviceImportSettingsTab().tabItem { Label("Device Import", systemImage: "externaldrive") }
        }
        .frame(width: 560, height: 480)
    }
}

// MARK: - Providers

struct ProviderSettingsTab: View {
    @Environment(AppEnvironment.self) private var app
    @State private var selectionID: String?
    @State private var draftName = ""
    @State private var draftKind: ProviderKind = .openAI
    @State private var draftBaseURL = ""
    @State private var draftModel = ""
    @State private var draftKey = ""
    @State private var capability: ImageCapability = .unknown
    @State private var testing = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectionID) {
                ForEach(app.profiles) { profile in
                    HStack {
                        Image(systemName: icon(for: profile.kind))
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) {
                            Text(profile.displayName).font(TypeStyles.rowTitle).lineLimit(1)
                            Text(profile.modelID).font(TypeStyles.monoDetail)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        }
                        Spacer(minLength: 8)
                        if profile.id == app.activeProfile()?.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                                .accessibilityLabel("Used for transcription")
                        }
                        if app.hasStoredKey(for: profile.id) {
                            Image(systemName: "key.fill").foregroundStyle(.secondary)
                                .accessibilityLabel("API key stored")
                        }
                    }
                    .tag(profile.id)
                }
            }
            .frame(height: 160)
            // Inline buttons: .toolbar is not reliably rendered on a
            // Settings-scene TabView page.
            HStack {
                Button { addProfile() } label: { Label("Add Provider", systemImage: "plus") }
                Button(role: .destructive) { deleteSelected() } label: { Label("Remove", systemImage: "minus") }
                    .disabled(selectionID == nil)
                Spacer()
            }
            .padding(.horizontal).padding(.vertical, 6)
            Divider()
            editor
                .padding()
        }
        .onAppear { select(app.profiles.first) }
        .onChange(of: selectionID) { _, new in
            select(app.profiles.first { $0.id == new })
        }
    }

    private var editor: some View {
        Form {
            Picker("Used for transcription", selection: Binding(
                get: { app.activeProfileID ?? app.profiles.first?.id },
                set: { app.activeProfileID = $0 })) {
                ForEach(app.profiles) { profile in
                    Text(profile.displayName).tag(profile.id as String?)
                }
            }
            .disabled(app.profiles.isEmpty)
            TextField("Display name", text: $draftName)
            Picker("Adapter", selection: $draftKind) {
                Text("OpenAI").tag(ProviderKind.openAI)
                Text("Anthropic").tag(ProviderKind.anthropic)
                Text("OpenAI-compatible").tag(ProviderKind.openAICompatible)
            }
            TextField("Base URL", text: $draftBaseURL)
                .font(TypeStyles.monoDetail)
            HStack {
                TextField("Model ID", text: $draftModel)
                    .font(TypeStyles.monoDetail)
                Menu("Suggested") {
                    ForEach(ProviderPresets.suggestedVisionModels[draftKind] ?? [], id: \.self) { model in
                        Button(model) { draftModel = model }
                    }
                }
                .fixedSize()
            }
            SecureField("API key (stored in Keychain)", text: $draftKey)
            HStack {
                Button("Test Connection") {
                    Task { await testCapability() }
                }
                .disabled(testing || draftModel.isEmpty)
                if testing { ProgressView().controlSize(.small) }
                capabilityLabel
                Spacer()
                Button("Save Profile") { saveProfile() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftName.isEmpty || draftModel.isEmpty)
            }
            Text("The test sends one tiny synthetic image — never a page from your notes — to verify authentication and image support for the exact model.")
                .font(TypeStyles.rowSecondary)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var capabilityLabel: some View {
        Group {
            switch capability {
            case .unknown:
                EmptyView()
            case .verified:
                Label("Verified", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            case .rejected(let reason):
                VStack(alignment: .leading) {
                    Label("Not usable", systemImage: "xmark.seal.fill").foregroundStyle(.red)
                    Text(reason).font(TypeStyles.rowSecondary).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }

    private func icon(for kind: ProviderKind) -> String {
        switch kind {
        case .openAI: return "circle.hexagongrid"
        case .anthropic: return "sparkle"
        case .openAICompatible: return "point.3.connected.trianglepath.dotted"
        }
    }

    private func select(_ profile: ProviderProfile?) {
        guard let profile else { return }
        selectionID = profile.id
        draftName = profile.displayName
        draftKind = profile.kind
        draftBaseURL = profile.baseURL.absoluteString
        draftModel = profile.modelID
        draftKey = ""
        capability = .unknown
    }

    private func addProfile() {
        // A fresh instance each time: the shared `custom` preset carries one
        // fixed UUID for the whole process, and duplicate ids corrupt the list.
        let next = ProviderProfile(
            displayName: "New Provider",
            kind: ProviderPresets.custom.kind,
            baseURL: ProviderPresets.custom.baseURL,
            modelID: ProviderPresets.custom.modelID)
        app.saveProfiles(app.profiles + [next])
        select(next)
    }

    private func deleteSelected() {
        guard let selectionID else { return }
        try? app.credentials.deleteSecret(forProfileID: selectionID)
        app.saveProfiles(app.profiles.filter { $0.id != selectionID })
        select(app.profiles.first)
    }

    private func saveProfile() {
        let url = URL(string: draftBaseURL.trimmingCharacters(in: .whitespaces))
        guard let url, url.host != nil else {
            app.appendActivity(title: "Provider not saved",
                               detail: "Base URL must include a host, e.g. https://api.example.com/v1.")
            return
        }
        // No selection means the editor holds a brand-new provider.
        let id = selectionID ?? UUID().uuidString
        let updated = ProviderProfile(id: id, displayName: draftName.trimmingCharacters(in: .whitespaces),
                                      kind: draftKind, baseURL: url,
                                      modelID: draftModel.trimmingCharacters(in: .whitespaces))
        // Key-host binding: a changed endpoint must never silently reuse the
        // old secret for a new host — clear it and require re-entry.
        if let previous = app.profiles.first(where: { $0.id == id }),
           previous.baseURL.host != url.host || previous.baseURL.scheme != url.scheme {
            try? app.credentials.deleteSecret(forProfileID: id)
            capability = .unknown
            app.appendActivity(title: "API key cleared",
                               detail: "Endpoint changed for \(updated.displayName) — re-enter the key for the new host.")
        }
        if app.profiles.contains(where: { $0.id == id }) {
            app.saveProfiles(app.profiles.map { $0.id == id ? updated : $0 })
        } else {
            app.saveProfiles(app.profiles + [updated])
            selectionID = id
        }
        if !draftKey.isEmpty {
            app.storeAPIKey(draftKey, for: id)
            draftKey = ""
        }
        app.appendActivity(title: "Saved provider \(updated.displayName)")
    }

    private func testCapability() async {
        guard let id = selectionID,
              let url = URL(string: draftBaseURL.trimmingCharacters(in: .whitespaces)) else { return }
        let profile = ProviderProfile(id: id, displayName: draftName, kind: draftKind,
                                      baseURL: url, modelID: draftModel.trimmingCharacters(in: .whitespaces))
        if !draftKey.isEmpty {
            app.storeAPIKey(draftKey, for: id)
        }
        testing = true
        defer { testing = false }
        let runner = OcrRunner(catalog: app.catalog, transport: URLSessionTransport(),
                               credentials: app.credentials, renderer: app.renderer, clock: app.clock)
        capability = await runner.probeImageCapability(profile: profile)
    }
}

// MARK: - Device import

struct DeviceImportSettingsTab: View {
    @Environment(AppEnvironment.self) private var app
    @AppStorage("adbExecutablePath") private var adbPath = ""
    @AppStorage("autoImportEnabled") private var autoImport = true

    @State private var newRootPath = "/sdcard/note"

    var body: some View {
        Form {
            Section("adb executable") {
                HStack {
                    TextField("Path", text: $adbPath)
                        .font(TypeStyles.monoDetail)
                    Button("Browse…") { browseADB() }
                    Button("Verify") { Task { await app.configureADB(path: adbPath) } }
                }
                if let version = app.adbVersion {
                    Label(version, systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                if let error = app.adbPathError {
                    Label(error, systemImage: "xmark.circle").foregroundStyle(.red)
                }
                Text("Install Android platform-tools yourself (developer.android.com/tools/releases/platform-tools); Boox Bridge never bundles or downloads adb.")
                    .font(TypeStyles.rowSecondary).foregroundStyle(.secondary)
            }
            Section("Automatic import") {
                Toggle("Import enrolled folders when the device connects", isOn: $autoImport)
                Text("Only while Boox Bridge is running, only for folders you enrolled below. Copying is one-way: nothing on the device is ever deleted, renamed, or moved.")
                    .font(TypeStyles.rowSecondary).foregroundStyle(.secondary)
            }
            Section("Enrolled export folders") {
                ForEach(app.importRoots) { root in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(root.displayName).font(TypeStyles.rowTitle)
                            Text("\(root.remoteRoot.raw) · \(root.serial)")
                                .font(TypeStyles.monoDetail).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        Spacer()
                        Button("Remove") {
                            try? app.catalog.removeRoot(id: root.id)
                            app.refreshLibrary()
                        }
                    }
                }
                HStack {
                    TextField("Device folder", text: $newRootPath)
                        .font(TypeStyles.monoDetail)
                    Button("Enroll Current Device") { enrollCurrent() }
                        .disabled(app.selectedSerial == nil)
                }
                Text("First time: on the Boox, enable PDF auto-export for your notebooks (Notes → export settings), pick the output folder, then enroll that folder here. /sdcard/note is the usual location on recent firmware.")
                    .font(TypeStyles.rowSecondary).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func browseADB() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        adbPath = url.path
        Task { await app.configureADB(path: adbPath) }
    }

    private func enrollCurrent() {
        guard let serial = app.selectedSerial,
              let root = try? RemotePath(newRootPath) else { return }
        let importRoot = ImportRoot(id: UUID().uuidString, serial: serial, remoteRoot: root,
                                    displayName: root.lastComponent, enrolledAt: Date())
        app.enrollRoot(importRoot)
        app.refreshLibrary()
    }
}
