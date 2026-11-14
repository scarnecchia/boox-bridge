// pattern: Imperative Shell

import Foundation

public enum StorageError: Error, Equatable, Sendable, CustomStringConvertible {
    case stagingCommitFailed(String)
    case blobMissing(String)

    public var description: String {
        switch self {
        case .stagingCommitFailed(let d): return "failed to commit staged file into managed storage: \(d)"
        case .blobMissing(let h): return "content blob missing for \(h)"
        }
    }
}

public final class ManagedStorage: Sendable {
    public let rootURL: URL
    // Computed, not stored: the Apple SDK does not mark FileManager Sendable.
    // `.default` is a documented thread-safe singleton, so per-call access
    // is equivalent.
    private var fileManager: FileManager { FileManager.default }

    public init(rootURL: URL) throws {
        self.rootURL = rootURL
        for directory in [rootURL.appendingPathComponent("blobs", isDirectory: true),
                          rootURL.appendingPathComponent("staging", isDirectory: true),
                          rootURL.appendingPathComponent("previews", isDirectory: true)] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    /// Unique staging directory for one pull attempt.
    public func newStagingDirectory() throws -> URL {
        let stagingRoot = rootURL.appendingPathComponent("staging", isDirectory: true)
        let url = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Move a validated staged file into content-addressed storage.
    /// Returns the blob URL; if the blob already existed (same content seen
    /// before), the staged copy is removed and the existing path returned.
    public func commit(stagedFile: URL, contentSHA256: String) throws -> URL {
        let blobURL = self.blobURL(for: contentSHA256)
        do {
            try fileManager.createDirectory(at: blobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: blobURL.path) {
                try? fileManager.removeItem(at: stagedFile)
                return blobURL
            }
            try fileManager.moveItem(at: stagedFile, to: blobURL)
            return blobURL
        } catch {
            throw StorageError.stagingCommitFailed("\(contentSHA256): \(error.localizedDescription)")
        }
    }

    public func blobURL(for contentSHA256: String) -> URL {
        let prefix = String(contentSHA256.prefix(2))
        return rootURL.appendingPathComponent("blobs", isDirectory: true)
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(contentSHA256)
    }

    public func blobExists(contentSHA256: String) -> Bool {
        fileManager.fileExists(atPath: blobURL(for: contentSHA256).path)
    }

    public func originalURL(revisionSHA256: String) throws -> URL {
        let url = blobURL(for: revisionSHA256)
        guard fileManager.fileExists(atPath: url.path) else {
            throw StorageError.blobMissing(revisionSHA256)
        }
        return url
    }

    /// Remove every staging directory. Called at startup: orphaned staging
    /// from a crashed run is garbage; committed content lives in blobs/.
    public func cleanupOrphanStaging() {
        let stagingRoot = rootURL.appendingPathComponent("staging", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: stagingRoot, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Discard one staging directory after a failed/deferred pull.
    public func discardStaging(_ directory: URL) {
        try? fileManager.removeItem(at: directory)
    }

    public func previewCacheURL(revisionID: Int64, pageIndex: Int) -> URL {
        rootURL.appendingPathComponent("previews", isDirectory: true)
            .appendingPathComponent("rev\(revisionID)-p\(pageIndex).png")
    }
}
