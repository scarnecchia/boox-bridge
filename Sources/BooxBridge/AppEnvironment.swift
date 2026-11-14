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

/// Which slice of the library the list shows. `catalogFolder` maps to the
/// catalog filter: nil = everything, "" = unfiled, a name = that folder.
enum LibraryFolderFilter: Hashable {
    case all
    case unfiled
    case named(String)

    var catalogFolder: String? {
        switch self {
        case .all: return nil
        case .unfiled: return ""
        case .named(let name): return name
        }
    }

    var label: String {
        switch self {
        case .all: return "All Notes"
        case .unfiled: return "Unfiled"
        case .named(let name): return name
        }
    }
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
    /// Persisted terminal transcription jobs (newest first, capped): failures
    /// with reasons and completed pages, so auth/render failures and
    /// interrupted recoveries surface even when the queue is empty.
    private(set) var jobHistory: [OcrJob] = []
    private(set) var selectedSerial: String?
    private(set) var adbVersion: String?
    private(set) var adbPathError: String?
    private(set) var folders: [String] = []

    var searchText: String = "" {
        didSet { Task { await refreshSearch() } }
    }

    var folderFilter: LibraryFolderFilter = .all {
        didSet { refreshLibrarySync() }
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
    private var ocrPollTask: Task<Void, Never>?
    private var drainOwnership = OCRDrainOwnership()

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
                clock: clock,
                fingerprinter: PDFKitPageFingerprinter()
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
            documents = try catalog.listDocuments(folder: folderFilter.catalogFolder)
            folders = try catalog.distinctFolders()
            activeJobs = try catalog.activeJobs()
        } catch {
            appendActivity(title: "Library refresh failed", detail: String(describing: error))
        }
        rebuildJobHistory()
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

    /// Indices of the current revision's pages that have no transcription
    /// text yet — the default OCR target so carried-over pages from an
    /// updated import are never billed twice.
    func pagesAwaitingTranscription(documentID: Int64) -> [Int] {
        guard let document = document(id: documentID) else { return [] }
        return pages(revisionID: document.currentPageRevisionID)
            .filter { $0.rawTranscription.isEmpty && $0.effectiveText.isEmpty }
            .map(\.pageIndex)
    }

    func updateTranscript(pageID: Int64, text: String) {
        do {
            try catalog.updateEffectiveText(pageID: pageID, text: text, at: clock.now())
        } catch {
            appendActivity(title: "Could not save edit", detail: String(describing: error))
        }
    }

    /// Library-only deletion: no ADB side effects, originals retained.
    func deleteDocuments(_ documentIDs: [Int64]) {
        guard !documentIDs.isEmpty else { return }
        try? catalog.markDocumentsDeleted(documentIDs, at: clock.now())
        appendActivity(title: documentIDs.count == 1 ? "Removed 1 note" : "Removed \(documentIDs.count) notes")
        refreshLibrarySync()
    }

    /// Assign notes to a library folder ("" removes them from any folder).
    func moveToFolder(_ documentIDs: [Int64], folder: String) {
        guard !documentIDs.isEmpty else { return }
        do {
            try catalog.setFolder(documentIDs: documentIDs, folder: folder, at: clock.now())
            let name = folder.trimmingCharacters(in: .whitespacesAndNewlines)
            appendActivity(title: name.isEmpty
                           ? "Removed \(documentIDs.count) note(s) from folder"
                           : "Moved \(documentIDs.count) note(s) to “\(name)”")
        } catch {
            appendActivity(title: "Move failed", detail: String(describing: error))
        }
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
        if s.duplicates > 0 { parts.append("\(s.duplicates) duplicate(s) skipped") }
        if s.pagesCarried > 0 { parts.append("\(s.pagesCarried) page(s) carried over") }
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
        let targets = indices ?? pagesAwaitingTranscription(documentID: documentID)
        guard !targets.isEmpty else {
            appendActivity(title: "OCR skipped",
                           detail: "Every page already has transcription text.")
            return
        }
        // The store returns the job id when it enqueued or reset the job,
        // nil when an active job with the same identity already exists, and
        // throws on real failures. All three are reported distinctly: a
        // deduplicated page is an accurate zero, never a swallowed error.
        var enqueued = 0
        var alreadyQueued = 0
        var failures: [String] = []
        for index in targets {
            do {
                if try catalog.enqueueJob(
                    revisionID: revisionID, pageIndex: index, profileID: profile.id,
                    modelID: profile.modelID, promptVersion: PromptVersion.current,
                    at: clock.now()) != nil {
                    enqueued += 1
                } else {
                    alreadyQueued += 1
                }
            } catch {
                failures.append("page \(index + 1): \(String(describing: error))")
            }
        }
        let outcome = EnqueueOutcome.report(
            enqueued: enqueued, alreadyQueued: alreadyQueued, failures: failures,
            providerName: profile.displayName, modelID: profile.modelID)
        appendActivity(title: outcome.activityTitle, detail: outcome.activityDetail)
        refreshLibrarySync()
        if outcome.enqueued > 0 {
            startOCRDrain()
        }
    }

    /// True while a drain task owns the queue; drives the Cancel/Resume
    /// affordance in the Activity queue section.
    var isOCRDraining: Bool { drainOwnership.isOwned }

    /// Start (or chain-start) the queue drain. The OCRDrainOwnership state
    /// machine keeps exactly one runner: a start while a drain is live only
    /// arms a chained restart and never cancels in-flight work (the live
    /// drain loop re-claims the queue every iteration, so new pages usually
    /// join the current run; if it was already finishing, the chained drain
    /// launches on its actual termination). Exactly one runner means the
    /// store's nextQueuedJob→mark-running claim — which is not atomic across
    /// concurrent runners — can never be raced by two in-process runners.
    func startOCRDrain() {
        switch drainOwnership.requestStart() {
        case .launch(let generation):
            spawnDrain(generation: generation)
        case .restartArmed:
            // Deliberately no cancellation: aborting the live run would mark
            // its in-flight page terminally failed and waste the billed
            // request; the queued pages flow without interruption instead.
            appendActivity(title: "OCR pages queued",
                           detail: "The running transcription continues and picks the new pages up without interruption.")
        }
    }

    private func spawnDrain(generation: Int) {
        let runner = OcrRunner(
            catalog: catalog, transport: URLSessionTransport(),
            credentials: credentials, renderer: renderer, clock: clock
        )
        let profiles = self.profiles
        ocrTask = Task { [weak self] in
            await runner.drain(profileResolver: { id in
                profiles.first { $0.id == id }
            })
            // Read cancellation inside the task: drain returns normally even
            // when cancelled, so this flag is how completion learns the run
            // ended by request rather than by an emptied queue.
            let wasCancelled = Task.isCancelled
            await MainActor.run { self?.drainTaskDidFinish(generation: generation, wasCancelled: wasCancelled) }
        }
        // Publish running/progress transitions while the drain works; the
        // Activity queue and the detail editor both read these slices.
        ocrPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                await MainActor.run { self?.refreshOCRViews() }
            }
        }
    }

    private func cancelDrainTask(generation: Int) {
        // Stale guard: only the current owner's task may be cancelled.
        guard drainOwnership.generationToCancel() == generation else { return }
        ocrTask?.cancel()
        ocrPollTask?.cancel()
    }

    /// Ownership retires only on the owning generation's completion; a stale
    /// completion must never clear a newer task's handle or unlock a second
    /// runner.
    private func drainTaskDidFinish(generation: Int, wasCancelled: Bool) {
        let decision = drainOwnership.taskDidFinish(generation: generation)
        if case .ignoreStale = decision { return }
        ocrTask = nil
        ocrPollTask?.cancel()
        ocrPollTask = nil
        if wasCancelled { finishCancelledDrain() }
        refreshLibrarySync()
        if case .relaunch(let next) = decision {
            spawnDrain(generation: next)
        } else if wasCancelled {
            appendActivity(title: "OCR stopped",
                           detail: "Queued pages remain queued; resume or retry to continue.")
        }
    }

    /// After a cancelled drain no runner exists to retire a job the transport
    /// aborted mid-flight; without this sweep it would stay "running" until
    /// the next launch recovery, which never runs mid-session.
    private func finishCancelledDrain() {
        guard let running = try? catalog.activeJobs() else { return }
        var sweepErrors: [String] = []
        for job in running where job.state == .running {
            do {
                try catalog.updateJob(
                    id: job.id, state: .failed, attempts: job.attempts,
                    lastError: "cancelled before completion — retry to re-run", at: clock.now())
            } catch {
                sweepErrors.append("job \(job.id): \(String(describing: error))")
            }
        }
        if !sweepErrors.isEmpty {
            appendActivity(title: "OCR stop cleanup failed", detail: sweepErrors.joined(separator: "; "))
        }
    }

    func cancelOCRDrain() {
        // requestCancel also disarms any restart a mid-run start armed, so a
        // user stop can never chain into further paid OCR work once the
        // cancelled task reports its actual termination.
        switch drainOwnership.requestCancel() {
        case .idle:
            appendActivity(title: "OCR idle", detail: "No transcription is running.")
        case .cancel(let generation):
            cancelDrainTask(generation: generation)
            appendActivity(title: "OCR cancelling",
                           detail: "Stopping at the next page boundary. A request already sent may still have been billed.")
        }
    }

    /// Re-enqueue a terminal job with its original identity. Non-nil counts
    /// as queued (the store resets the terminal row), nil means an active job
    /// with the same identity already exists, and a throw is surfaced — none
    /// is silently folded into the queued count.
    func retryOCRJob(_ job: OcrJob) {
        do {
            if try catalog.enqueueJob(
                revisionID: job.revisionID, pageIndex: job.pageIndex, profileID: job.profileID,
                modelID: job.modelID, promptVersion: job.promptVersion, at: clock.now()) != nil {
                appendActivity(title: "OCR retry queued",
                               detail: "Page \(job.pageIndex + 1) re-queued for \(job.modelID).")
                refreshLibrarySync()
                startOCRDrain()
            } else {
                appendActivity(title: "OCR retry skipped",
                               detail: "Page \(job.pageIndex + 1) already has a queued or running job.")
            }
        } catch {
            appendActivity(title: "OCR retry failed", detail: String(describing: error))
        }
    }

    /// Mid-batch refresh. Re-reads the document snapshot as well: the detail
    /// editor's body observes `documents`, so re-setting it re-fetches page
    /// transcripts and lets the draft policy reload clean drafts as OCR
    /// commits within the same revision. Read errors keep the previous
    /// snapshot: the poll is best-effort and must not spam the activity feed
    /// once a second during a database hiccup; authoritative failures surface
    /// through refreshLibrarySync.
    private func refreshOCRViews() {
        documents = (try? catalog.listDocuments(folder: folderFilter.catalogFolder)) ?? documents
        activeJobs = (try? catalog.activeJobs()) ?? activeJobs
        rebuildJobHistory()
    }

    /// Terminal transcription jobs for the current revisions of live
    /// documents, newest first, capped. Per-document read errors skip that
    /// document; primary store failures already surface via
    /// refreshLibrarySync's listDocuments path.
    private func rebuildJobHistory() {
        var terminal: [OcrJob] = []
        for document in documents {
            let jobs = (try? catalog.jobs(revisionID: document.currentPageRevisionID)) ?? []
            terminal.append(contentsOf: jobs.filter {
                $0.state == .succeeded || $0.state == .failed || $0.state == .cancelled
            })
        }
        terminal.sort { $0.id > $1.id }
        jobHistory = Array(terminal.prefix(Self.jobHistoryLimit))
    }

    private static let jobHistoryLimit = 50

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
