// pattern: Imperative Shell
// Safety rules enforced here (tested by usbReconnectImportIntegration,
// incrementalImportIntegration, changingExportIntegration,
// catalogRecoveryIntegration):
//   - A failed or partial listing aborts the sync — never infer deletions.
//   - A file whose remote metadata changed mid-pull is deferred, not committed.
//   - A local hash mismatch vs device sha256 (when available) is deferred.
//   - Only validated documents replace a current revision; anything invalid
//     keeps the previous revision intact.
//   - Concurrent syncs for the same root coalesce into one run.

import Foundation

public struct InvalidImportFile: Equatable, Sendable {
    public let path: String
    public let reason: String

    public init(path: String, reason: String) {
        self.path = path
        self.reason = reason
    }
}

public struct ImportSummary: Equatable, Sendable {
    public var newDocuments = 0
    public var newRevisions = 0
    public var unchanged = 0
    /// Paths skipped because their content already lives in the library.
    public var duplicates = 0
    /// Pages whose transcription text carried over into a new revision.
    public var pagesCarried = 0
    public var deferredUnstable: [String] = []
    public var invalidFiles: [InvalidImportFile] = []
    public var unsupported: [ImportPlan.UnsupportedItem] = []
    public var errors: [String] = []

    public init() {}

    public var didChangeLibrary: Bool { newDocuments > 0 || newRevisions > 0 }
}

public enum ImportError: Error, Equatable, Sendable, CustomStringConvertible {
    case listingFailed(root: String, reason: String)
    case deviceNotReady(String)

    public var description: String {
        switch self {
        case .listingFailed(let root, let reason): return "could not list \(root): \(reason)"
        case .deviceNotReady(let serial): return "device \(serial) is not ready for import"
        }
    }
}

public actor DeviceImportService {
    private let transport: DeviceTransport
    private let catalog: CatalogStore
    private let storage: ManagedStorage
    private let hasher: ContentHashing
    private let validator: DocumentValidating
    private let clock: WallClock
    private let fingerprinter: PageFingerprinting?

    private var runningRoots: Set<String> = []
    private var inFlight: [String: Task<ImportSummary, Error>] = [:]

    public init(
        transport: DeviceTransport,
        catalog: CatalogStore,
        storage: ManagedStorage,
        hasher: ContentHashing = SHA256Hasher(),
        validator: DocumentValidating = SniffingValidator(),
        clock: WallClock = SystemClock(),
        fingerprinter: PageFingerprinting? = nil
    ) {
        self.transport = transport
        self.catalog = catalog
        self.storage = storage
        self.hasher = hasher
        self.validator = validator
        self.clock = clock
        self.fingerprinter = fingerprinter
    }

    /// Startup recovery: orphaned staging directories are garbage; committed
    /// content lives in blobs/.
    public func recoverAfterLaunch() {
        storage.cleanupOrphanStaging()
    }

    /// Sync one enrolled root. Re-entrant calls coalesce onto the running
    /// task instead of racing a second copy over the same device tree.
    public func sync(root: ImportRoot) async throws -> ImportSummary {
        if let existing = inFlight[root.id] {
            return try await existing.value
        }
        let task = Task<ImportSummary, Error> { [self] in
            defer { inFlight[root.id] = nil }
            return try await runSync(root: root)
        }
        inFlight[root.id] = task
        return try await task.value
    }

    private func runSync(root: ImportRoot) async throws -> ImportSummary {
        var summary = ImportSummary()

        let listing: [RemoteFileRecord]
        do {
            listing = try await transport.listFiles(root: root.remoteRoot, serial: root.serial)
        } catch {
            throw ImportError.listingFailed(root: root.remoteRoot.raw, reason: String(describing: error))
        }

        let snapshots = (try? catalog.snapshots(forSerial: root.serial, rootID: root.id)) ?? [:]
        let plan = ImportPlanner.plan(listing: listing, snapshots: snapshots, root: root.remoteRoot)
        summary.unchanged = plan.unchangedCount
        summary.unsupported = plan.unsupported

        for pull in plan.pulls {
            let relative = ImportPlanner.relativePath(of: pull.record.path, root: root.remoteRoot)
            do {
                let result = try await importOne(pull: pull, root: root,
                                                 previousRevisionSHA256: snapshots[relative]?.revisionSHA256)
                switch result.outcome {
                case .newDocument: summary.newDocuments += 1
                case .newRevision: summary.newRevisions += 1
                case .unchanged: summary.unchanged += 1
                case .duplicate: summary.duplicates += 1
                }
                summary.pagesCarried += result.carriedPages
            } catch let error as DocumentValidationError {
                summary.invalidFiles.append(InvalidImportFile(path: pull.record.path.raw, reason: String(describing: error)))
            } catch ImportErrorDeferred.unstable(let reason) {
                summary.deferredUnstable.append(reason)
            } catch {
                summary.errors.append("\(pull.record.path.raw): \(String(describing: error))")
            }
        }
        return summary
    }

    private enum ImportErrorDeferred: Error {
        case unstable(String)
    }

    private struct ImportResult {
        let outcome: ImportOutcome
        let carriedPages: Int
    }

    private func importOne(pull: ImportPlan.Pull, root: ImportRoot,
                           previousRevisionSHA256: String?) async throws -> ImportResult {
        let remote = pull.record.path
        let serial = root.serial

        guard let preStat = try await transport.stat(remote: remote, serial: serial) else {
            throw ImportErrorDeferred.unstable("file vanished before pull: \(remote.raw)")
        }

        let staging = try storage.newStagingDirectory()
        defer { storage.discardStaging(staging) }

        let stagedFile = try await transport.pull(remote: remote, intoStagingDirectory: staging, serial: serial)

        // Post-pull metadata: if the device says the file changed during the
        // copy, the staged bytes are not a consistent revision — defer.
        guard let postStat = try await transport.stat(remote: remote, serial: serial) else {
            throw ImportErrorDeferred.unstable("file vanished after pull: \(remote.raw)")
        }
        guard preStat.sizeBytes == postStat.sizeBytes,
              preStat.modifiedEpochSeconds == postStat.modifiedEpochSeconds else {
            throw ImportErrorDeferred.unstable("file changed during export: \(remote.raw)")
        }

        // Content integrity: local hash (always) vs device hash (when the
        // toybox tooling provides one).
        let localHash = try hasher.sha256Hex(fileAt: stagedFile)
        if let remoteHash = try await transport.remoteSHA256(remote: remote, serial: serial),
           remoteHash.lowercased() != localHash {
            throw ImportErrorDeferred.unstable("hash mismatch during transfer: \(remote.raw)")
        }

        // Format validation before anything replaces a valid revision.
        let validation = try validator.validate(fileAt: stagedFile)
        guard validation.pageCount <= DocumentLimits.maxPageCount else {
            throw DocumentValidationError.tooManyPages(pages: validation.pageCount, limit: DocumentLimits.maxPageCount)
        }
        guard !validation.isEncrypted else { throw DocumentValidationError.encrypted }

        let attributes = try FileManager.default.attributesOfItem(atPath: stagedFile.path)
        let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? pull.record.sizeBytes

        // Page carry-over is best-effort: fingerprint failures degrade to no
        // carry-over (those pages start blank and can be transcribed
        // manually), never to a failed import.
        var carries: [PageCarry.Match] = []
        if let fingerprinter, let previousSHA = previousRevisionSHA256,
           let previousURL = try? storage.originalURL(revisionSHA256: previousSHA) {
            let oldPages = (try? fingerprinter.sha256PerPage(fileAt: previousURL)) ?? [:]
            let newPages = (try? fingerprinter.sha256PerPage(fileAt: stagedFile)) ?? [:]
            carries = PageCarry.plan(old: oldPages, new: newPages)
        }

        // Commit content first; the catalog transaction references it.
        _ = try storage.commit(stagedFile: stagedFile, contentSHA256: localHash)

        let relative = ImportPlanner.relativePath(of: remote, root: root.remoteRoot)
        let outcome = try catalog.commitImport(
            key: DocumentKey(serial: serial, rootID: root.id, relativePath: relative),
            kind: validation.kind,
            contentSHA256: localHash,
            sizeBytes: sizeBytes,
            pageCount: validation.pageCount,
            remoteMtime: postStat.modifiedEpochSeconds,
            remoteSize: postStat.sizeBytes,
            at: clock.now(),
            carryPageMatches: carries
        )
        let carriedPages: Int
        if case .newRevision = outcome { carriedPages = carries.count } else { carriedPages = 0 }
        return ImportResult(outcome: outcome, carriedPages: carriedPages)
    }
}
