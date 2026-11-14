// pattern: Imperative Shell

import Foundation

public enum DeviceFileError: Error, Equatable, Sendable, CustomStringConvertible {
    case outsideBrowseRoot(path: String, root: String)
    case destinationExistsNeedsConfirmation(path: String)
    case publishRace(path: String)
    case uploadVerificationFailed(path: String, detail: String)
    case invalidName(String)

    public var description: String {
        switch self {
        case .outsideBrowseRoot(let p, let r): return "path \(p) is outside the selected folder \(r)"
        case .destinationExistsNeedsConfirmation(let p): return "\(p) already exists on the device. Remote replacement is disabled in this release — move or remove the existing file on the device, then upload again"
        case .publishRace(let p): return "destination \(p) appeared during upload; nothing was overwritten"
        case .uploadVerificationFailed(let p, let d): return "uploaded file \(p) failed verification: \(d)"
        case .invalidName(let n): return "'\(n)' is not a valid name"
        }
    }
}

public struct RemoteEntry: Equatable, Sendable, Identifiable {
    public let path: RemotePath
    public let sizeBytes: Int64
    public let modifiedEpochSeconds: Int64
    public let isDirectory: Bool

    public var id: String { path.raw }
    public var name: String { path.lastComponent }
}

public actor DeviceFileService {
    private let transport: DeviceTransport
    public let browseRoot: RemotePath
    public let serial: String

    public init(transport: DeviceTransport, serial: String, browseRoot: RemotePath) {
        self.transport = transport
        self.serial = serial
        self.browseRoot = browseRoot
    }

    /// Direct children of `directory` (validated inside the browse root),
    /// directories first, then files, both alphabetical.
    public func entries(in directory: RemotePath) async throws -> [RemoteEntry] {
        try requireInRoot(directory)
        let all = try await transport.listEntries(root: directory, serial: serial)
        let depth = directory.components.count
        return all
            .filter { $0.path.components.count == depth + 1 }
            .map { RemoteEntry(
                path: $0.path,
                sizeBytes: $0.sizeBytes,
                modifiedEpochSeconds: $0.modifiedEpochSeconds,
                isDirectory: !$0.isRegularFile
            ) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    /// Download remote files into a local directory the user chose. Each
    /// file lands under a unique staging name first, then moves into place;
    /// an existing local file is only replaced with explicit consent.
    public func download(
        files: [RemotePath],
        intoLocalDirectory directory: URL,
        overwrite: Bool
    ) async throws -> [URL] {
        for file in files { try requireInRoot(file) }
        var written: [URL] = []
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        for file in files {
            let destination = directory.appendingPathComponent(file.lastComponent)
            if fm.fileExists(atPath: destination.path) && !overwrite {
                throw DeviceFileError.destinationExistsNeedsConfirmation(path: destination.lastPathComponent)
            }
            let staging = directory.appendingPathComponent(".booxbridge-download-\(UUID().uuidString)")
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            do {
                let staged = try await transport.pull(remote: file, intoStagingDirectory: staging, serial: serial)
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.moveItem(at: staged, to: destination)
                try? fm.removeItem(at: staging)
                written.append(destination)
            } catch {
                try? fm.removeItem(at: staging)
                throw error
            }
        }
        return written
    }

    /// Upload a local file into a remote folder inside the browse root.
    /// Publishes from an app-owned temporary sibling via `mv -n`, so a
    /// concurrent writer can never be overwritten — if the destination
    /// appeared, the upload aborts and the temp is cleaned up.
    public func upload(
        localFile: URL,
        toDirectory directory: RemotePath,
        overwrite: Bool
    ) async throws {
        try requireInRoot(directory)
        let fileName = localFile.lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != "..", !fileName.contains("\0") else {
            throw DeviceFileError.invalidName(fileName)
        }
        let destination = try directory.appending(fileName)
        try requireInRoot(destination)

        if let existing = try await transport.stat(remote: destination, serial: serial) {
            // Remote overwrite is DISABLED in this release: no tested adb
            // capability guarantees safe replacement (a remove+rename window
            // can destroy the existing file if anything fails mid-way).
            // The error tells the user to remove/rename on the device first.
            _ = existing
            throw DeviceFileError.destinationExistsNeedsConfirmation(path: destination.raw)
        }

        let tempPath = try directory.appending(RemoteTempName.tempName(for: fileName))
        do {
            try await transport.push(localFile: localFile, toRemote: tempPath, serial: serial)

            // Verify the staged bytes: the device must report the same size
            // we just pushed.
            guard let staged = try await transport.stat(remote: tempPath, serial: serial),
                  staged.isRegularFile else {
                throw DeviceFileError.uploadVerificationFailed(path: tempPath.raw, detail: "staged file missing after push")
            }
            let localSize = (try FileManager.default.attributesOfItem(atPath: localFile.path)[.size] as? NSNumber)?.int64Value ?? -1
            guard staged.sizeBytes == localSize else {
                throw DeviceFileError.uploadVerificationFailed(
                    path: tempPath.raw,
                    detail: "size mismatch (device \(staged.sizeBytes), local \(localSize))"
                )
            }

            if let existing = try await transport.stat(remote: destination, serial: serial), existing.isRegularFile {
                throw DeviceFileError.publishRace(path: destination.raw)
            }
            try await transport.moveRemoteNoClobber(from: tempPath, to: destination, serial: serial)

            // Confirm our bytes actually landed (a racing writer with mv -n
            // leaves the destination as theirs, and our temp still present).
            guard let final = try await transport.stat(remote: destination, serial: serial),
                  final.isRegularFile, final.sizeBytes == localSize else {
                // Our publish lost a race or was clobbered: nothing
                // overwritten by us; the catch path cleans our temp.
                throw DeviceFileError.publishRace(path: destination.raw)
            }
        } catch {
            // Cancel/disconnect mid-upload: originals preserved; the temp is
            // app-owned, so cleanup is safe and best-effort.
            try? await transport.removeRemote(path: tempPath, serial: serial)
            throw error
        }
    }

    /// Create a folder inside the browse root (explicit user action).
    public func createFolder(named name: String, in directory: RemotePath) async throws {
        try requireInRoot(directory)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.contains("\0") else {
            throw DeviceFileError.invalidName(name)
        }
        let target = try directory.appending(name)
        try requireInRoot(target)
        try await transport.makeDirectory(remote: target, serial: serial)
    }

    private func requireInRoot(_ path: RemotePath) throws {
        guard path.isWithin(browseRoot) else {
            throw DeviceFileError.outsideBrowseRoot(path: path.raw, root: browseRoot.raw)
        }
    }
}
