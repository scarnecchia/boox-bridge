// pattern: Imperative Shell
// AppEnvironment: observable application state wired to BooxBridgeCore
// services. Owns device polling, import triggering, library refresh, OCR
// enqueueing, and provider profiles. Scenario mode substitutes deterministic
// services behind the same seams — normal startup never enables fixtures.

import BooxBridgeCore
import Foundation
import Observation
import SwiftUI

enum DevicePhase: Equatable {
    case needsADBPath
    case noDevice
    case needsAuthorization(String)
    case offline(String)
    case ambiguous([String])
    case connected(String, model: String)
    case failure(String)

    var guidance: String {
        switch self {
        case .needsADBPath:
            return "Select the adb executable in Settings → Device Import."
        case .noDevice:
            return "No device detected. Connect the Boox over USB, unlock it, and check the cable."
        case .needsAuthorization(let serial):
            return "Device \(serial) is unauthorized. Enable USB debugging (Settings → About → tap build, then Developer options) and accept the debugging prompt on the device."
        case .offline(let serial):
            return "Device \(serial) is offline. Reconnect it or re-accept the USB debugging prompt."
        case .ambiguous(let serials):
            return "Multiple devices connected (\(serials.joined(separator: ", "))). Pick one in Settings → Device Import."
        case .connected(let serial, let model):
            return "Connected: \(model.isEmpty ? serial : model) (\(serial))"
        case .failure(let reason):
            return reason
        }
    }
}

struct ActivityEvent: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let title: String
    var detail: String?
}

@MainActor
@Observable
final class AppEnvironment {
    // Published state
    private(set) var devicePhase: DevicePhase = .noDevice
    private(set) var documents: [DocumentSummary] = []
    private(set) var searchResults: [CatalogStore.SearchHit] = []
    private(set) var activity: [ActivityEvent] = []
    private(set) var importSummaries: [String: ImportSummary] = [:]
    private(set) var activeJobs: [OcrJob] = []
    private(set) var selectedSerial: String?
    private(set) var adbVersion: String?
    private(set) var adbPathError: String?

    var searchText: String = "" {
        didSet { Task { await refreshSearch() } }
    }

    // Provider profiles (non-secret) persisted as JSON; secrets stay in Keychain.
    private(set) var profiles: [ProviderProfile] = []
    var activeProfileID: String?

    // Wired services
    let catalog: CatalogStore
    let storage: ManagedStorage
    let importer: DeviceImportService
    let credentials: KeychainCredentialStore
    let renderer: PDFKitPageRenderer
    let clock: WallClock
    let scenario: ScenarioKind?

    private let transportBox: TransportBox
    private var recoveryTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?
    private var ocrTask: Task<Void, Never>?

    struct TransportBox: Sendable {
        let makeTransport: @Sendable () throws -> DeviceTransport
        let fixedTransport: (any DeviceTransport)?
    }

    init(supportDirectory: URL, scenario: ScenarioKind? = nil) throws {
        self.scenario = scenario
        self.credentials = KeychainCredentialStore()
        self.clock = SystemClock()
        let catalogURL = supportDirectory.appendingPathComponent("catalog.sqlite")
        self.catalog = try CatalogStore.open(atPath: catalogURL.path)
        self.storage = try ManagedStorage(rootURL: supportDirectory.appendingPathComponent("library", isDirectory: true))
        self.renderer = PDFKitPageRenderer(storage: storage)
        let loadedProfiles = Self.loadProfiles(from: supportDirectory) ?? []
        self.profiles = loadedProfiles
        // Read the local, not self.profiles: stored vars cannot be read
        // until every stored property is initialized.
        self.activeProfileID = loadedProfiles.first?.id

        if let scenario {
            // Deterministic scenario mode: injected transport, seeded state.
            let services = ScenarioServices.build(scenario: scenario, supportDirectory: supportDirectory)
            self.transportBox = TransportBox(makeTransport: { services.transport }, fixedTransport: services.transport)
            self.importer = DeviceImportService(
                transport: services.transport, catalog: catalog, storage: storage,
                hasher: SHA256Hasher(), validator: SniffingValidator(), clock: clock
            )
            for root in services.enrolledRoots { try? catalog.enrollRoot(root) }
            for event in services.initialActivity { activity.append(event) }
            self.devicePhase = services.devicePhase
            self.selectedSerial = services.serial
        } else {
            let box = TransportBox(
                makeTransport: { @Sendable in
                    guard let path = AppPaths.defaults.string(forKey: "adbExecutablePath"), !path.isEmpty else {
                        throw AdbClientError.invalidExecutable("(not configured)")
                    }
                    return try AdbClient(executableURL: URL(fileURLWithPath: path))
                },
                fixedTransport: nil
            )
            self.transportBox = box
            self.importer = DeviceImportService(
                transport: ScenarioPassthroughTransport(box: box),
                catalog: catalog, storage: storage,
                hasher: SHA256Hasher(),
                validator: PDFKitDocumentValidator(storage: storage),
                clock: clock
            )
            if AppPaths.defaults.string(forKey: "adbExecutablePath") == nil {
                devicePhase = .needsADBPath
            }
        }

        // Launch recovery: orphan staging cleanup; interrupted OCR jobs
        // surface as resumable failures, never silently restarted.
        _ = try? catalog.recoverInterruptedJobs(at: clock.now())
        recoveryTask = Task { [importer] in
            await importer.recoverAfterLaunch()
        }
        refreshLibrarySync()
    }

    // MARK: - Lifecycle

    func startDeviceMonitoring() {
        guard pollingTask == nil, scenario == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollDevice()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopDeviceMonitoring() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollDevice() async {
        do {
            let transport = try transportBox.makeTransport()
            let devices = try await transport.listDevices()
            let selection = DeviceListParser.usbCandidate(devices)
            switch selection {
            case .single(let entry):
                selectedSerial = entry.serial
                let model = entry.properties["model"]?.replacingOccurrences(of: "_", with: " ") ?? ""
                devicePhase = .connected(entry.serial, model: model)
                await autoImportIfEligible(entry: entry)
            case .ambiguous(let entries):
                devicePhase = .ambiguous(entries.map(\.serial))
            case .needsAuthorization(let entry):
                devicePhase = .needsAuthorization(entry.serial)
            case .disconnectedOrOffline(let entry):
                devicePhase = .offline(entry.serial)
            case .none:
                devicePhase = .noDevice
            }
        } catch AdbClientError.invalidExecutable {
            devicePhase = .needsADBPath
        } catch {
            devicePhase = .failure(String(describing: error))
        }
    }

    private func autoImportIfEligible(entry: DeviceEntry) async {
        // Auto-import ONLY enrolled devices/roots, only while the app runs,
        // and only for the unambiguous USB candidate.
        guard AppPaths.defaults.bool(forKey: "autoImportEnabled") else { return }
        await syncNow(serial: entry.serial)
    }

    // MARK: - Library

    func refreshLibrarySync() {
        do {
            documents = try catalog.listDocuments()
            activeJobs = try catalog.activeJobs()
        } catch {
            appendActivity(title: "Library refresh failed", detail: String(describing: error))
        }
    }

    func refreshLibrary() {
        refreshLibrarySync()
    }

    func refreshSearch() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        searchResults = (try? catalog.search(matching: query)) ?? []
    }

    func document(id: Int64) -> DocumentSummary? {
        documents.first { $0.id == id } ?? (try? catalog.document(id: id))
    }

    func revisions(documentID: Int64) -> [RevisionRecord] {
        (try? catalog.revisions(documentID: documentID)) ?? []
    }

    func pages(revisionID: Int64) -> [PageTranscript] {
        (try? catalog.pages(revisionID: revisionID)) ?? []
    }

    func updateTranscript(pageID: Int64, text: String) {
        do {
            try catalog.updateEffectiveText(pageID: pageID, text: text, at: clock.now())
        } catch {
            appendActivity(title: "Could not save edit", detail: String(describing: error))
        }
    }

    func markDeleted(_ documentID: Int64) {
        // Library-only deletion: no ADB side effects, originals retained.
        try? catalog.markDocumentDeleted(documentID, at: clock.now())
        refreshLibrarySync()
    }

    func exportText(documentID: Int64, format: TranscriptFormat) -> String? {
        guard let document = document(id: documentID),
              let revisionID = document.currentPageRevisionID as Int64? else { return nil }
        let pages = pages(revisionID: revisionID)
        return TranscriptExporter().export(title: document.title, pages: pages, format: format)
    }

    // MARK: - Import

    func enrollRoot(_ root: ImportRoot) {
        try? catalog.enrollRoot(root)
    }

    var importRoots: [ImportRoot] {
        (try? catalog.listRoots()) ?? []
    }

    func syncNow(serial: String? = nil) async {
        let targetSerial = serial ?? selectedSerial
        guard let targetSerial else {
            appendActivity(title: "Sync skipped", detail: "No device selected.")
            return
        }
        let roots = importRoots.filter { $0.serial == targetSerial }
        guard !roots.isEmpty else {
            appendActivity(title: "Sync skipped", detail: "No import folders enrolled for this device yet (Settings → Device Import).")
            return
        }
        for root in roots {
            do {
                let summary = try await importer.sync(root: root)
                importSummaries[root.id] = summary
                appendActivity(
                    title: "Import finished: \(root.displayName)",
                    detail: summaryDescription(summary)
                )
            } catch {
                appendActivity(title: "Import failed: \(root.displayName)", detail: String(describing: error))
            }
        }
        refreshLibrarySync()
    }

    func summaryDescription(_ s: ImportSummary) -> String {
        var parts: [String] = []
        if s.newDocuments > 0 { parts.append("\(s.newDocuments) new") }
        if s.newRevisions > 0 { parts.append("\(s.newRevisions) updated") }
        if s.unchanged > 0 { parts.append("\(s.unchanged) unchanged") }
        if !s.deferredUnstable.isEmpty { parts.append("\(s.deferredUnstable.count) deferred (still exporting)") }
        if !s.invalidFiles.isEmpty { parts.append("\(s.invalidFiles.count) invalid") }
        if !s.unsupported.isEmpty { parts.append("\(s.unsupported.count) unsupported (\(s.unsupported.map(\.extensionName).joined(separator: ", ")))") }
        if !s.errors.isEmpty { parts.append("\(s.errors.count) errors") }
        return parts.isEmpty ? "Nothing to import." : parts.joined(separator: ", ")
    }

    // MARK: - Device files

    func fileService(browseRoot: RemotePath) throws -> DeviceFileService {
        let transport = try transportBox.makeTransport()
        let serial = selectedSerial ?? ""
        return DeviceFileService(transport: transport, serial: serial, browseRoot: browseRoot)
    }

    // MARK: - OCR

    func activeProfile() -> ProviderProfile? {
        profiles.first { $0.id == activeProfileID } ?? profiles.first
    }

    func enqueueOCR(documentID: Int64, pages indices: [Int]?) async {
        guard let profile = activeProfile() else {
            appendActivity(title: "OCR not started", detail: "No provider profile configured (Settings → Providers).")
            return
        }
        let storedKey: String?
        do {
            storedKey = try credentials.secret(forProfileID: profile.id)
        } catch {
            appendActivity(title: "OCR not started",
                           detail: "Keychain read failed for \(profile.displayName): \(String(describing: error))")
            return
        }
        guard storedKey?.isEmpty == false else {
            appendActivity(title: "OCR not started",
                           detail: "No API key stored for \(profile.displayName). Enter it in Settings → Providers and save.")
            return
        }
        guard let document = document(id: documentID),
              let revisionID = Int64(exactly: document.currentPageRevisionID) else { return }
        let targets = indices ?? Array(0..<max(document.pageCount, 0))
        var enqueued = 0
        for index in targets {
            if (try? catalog.enqueueJob(
                revisionID: revisionID, pageIndex: index, profileID: profile.id,
                modelID: profile.modelID, promptVersion: PromptVersion.current,
                at: clock.now())) != nil {
                enqueued += 1
            }
        }
        appendActivity(
            title: "OCR queued",
            detail: "\(enqueued) page(s) → \(profile.displayName) / \(profile.modelID). Remote requests may bill per page."
        )
        refreshLibrarySync()
        startOCRDrain()
    }

    func startOCRDrain() {
        guard ocrTask == nil else { return }
        let runner = OcrRunner(
            catalog: catalog, transport: URLSessionTransport(),
            credentials: credentials, renderer: renderer, clock: clock
        )
        let profiles = self.profiles
        ocrTask = Task { [weak self] in
            await runner.drain(profileResolver: { id in
                profiles.first { $0.id == id }
            })
            await MainActor.run { self?.ocrTask = nil; self?.refreshLibrarySync() }
        }
    }

    func cancelOCRDrain() {
        ocrTask?.cancel()
        ocrTask = nil
        appendActivity(title: "OCR cancelled", detail: "New pages stopped. A request already sent may still have been billed.")
    }

    // MARK: - Providers

    static func loadProfiles(from directory: URL) -> [ProviderProfile]? {
        let url = directory.appendingPathComponent("providers.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([ProviderProfile].self, from: data)
    }

    func saveProfiles(_ updated: [ProviderProfile]) {
        profiles = updated
        if activeProfileID == nil || !updated.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = updated.first?.id
        }
        if let directory = try? AppPaths.applicationSupport(),
           let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: directory.appendingPathComponent("providers.json"), options: .atomic)
        }
    }

    func storeAPIKey(_ key: String, for profileID: String) {
        do {
            try credentials.saveSecret(key, forProfileID: profileID)
        } catch {
            appendActivity(title: "Keychain error", detail: String(describing: error))
        }
    }

    func hasStoredKey(for profileID: String) -> Bool {
        guard let key = try? credentials.secret(forProfileID: profileID) else { return false }
        return !key.isEmpty
    }

    // MARK: - Settings

    func configureADB(path: String) async {
        let url = URL(fileURLWithPath: path)
        do {
            let client = try AdbClient(executableURL: url)
            adbVersion = try? await client.version()
            adbPathError = nil
            AppPaths.defaults.set(path, forKey: "adbExecutablePath")
            appendActivity(title: "adb configured", detail: adbVersion ?? path)
            await pollDevice()
        } catch {
            adbPathError = String(describing: error)
        }
    }

    // MARK: - Activity

    func appendActivity(title: String, detail: String? = nil) {
        activity.insert(ActivityEvent(date: clock.now(), title: title, detail: detail), at: 0)
    }
}

/// Passes through to the configured real transport; used so the importer
/// can be built once at launch and pick up Settings changes lazily.
struct ScenarioPassthroughTransport: DeviceTransport {
    let box: AppEnvironment.TransportBox

    var executableURL: URL { URL(fileURLWithPath: AppPaths.defaults.string(forKey: "adbExecutablePath") ?? "adb") }

    func listDevices() async throws -> [DeviceEntry] {
        try await box.makeTransport().listDevices()
    }
    func deviceProperties(serial: String, names: [String]) async throws -> [String: String] {
        try await box.makeTransport().deviceProperties(serial: serial, names: names)
    }
    func listFiles(root: RemotePath, serial: String) async throws -> [RemoteFileRecord] {
        try await box.makeTransport().listFiles(root: root, serial: serial)
    }
    func listEntries(root: RemotePath, serial: String) async throws -> [RemoteFileRecord] {
        try await box.makeTransport().listEntries(root: root, serial: serial)
    }
    func stat(remote: RemotePath, serial: String) async throws -> RemoteFileRecord? {
        try await box.makeTransport().stat(remote: remote, serial: serial)
    }
    func remoteSHA256(remote: RemotePath, serial: String) async throws -> String? {
        try await box.makeTransport().remoteSHA256(remote: remote, serial: serial)
    }
    func pull(remote: RemotePath, intoStagingDirectory: URL, serial: String) async throws -> URL {
        try await box.makeTransport().pull(remote: remote, intoStagingDirectory: intoStagingDirectory, serial: serial)
    }
    func push(localFile: URL, toRemote: RemotePath, serial: String) async throws {
        try await box.makeTransport().push(localFile: localFile, toRemote: toRemote, serial: serial)
    }
    func makeDirectory(remote: RemotePath, serial: String) async throws {
        try await box.makeTransport().makeDirectory(remote: remote, serial: serial)
    }
    func moveRemoteNoClobber(from: RemotePath, to: RemotePath, serial: String) async throws {
        try await box.makeTransport().moveRemoteNoClobber(from: from, to: to, serial: serial)
    }
    func removeRemote(path: RemotePath, serial: String) async throws {
        try await box.makeTransport().removeRemote(path: path, serial: serial)
    }
    func version() async throws -> String {
        try await box.makeTransport().version()
    }
}
