// pattern: Imperative Shell

import Foundation

public protocol DeviceTransport: Sendable {
    /// Path of the adb executable this transport runs (for diagnostics).
    var executableURL: URL { get }

    func listDevices() async throws -> [DeviceEntry]
    func deviceProperties(serial: String, names: [String]) async throws -> [String: String]
    /// Regular files under `root`, NUL-delimited listing. Throws on any
    /// malformed record — never fabricates an empty-but-successful listing.
    func listFiles(root: RemotePath, serial: String) async throws -> [RemoteFileRecord]
    /// Files AND directories under `root` (recursive; callers filter depth)
    /// for the bounded device file browser.
    func listEntries(root: RemotePath, serial: String) async throws -> [RemoteFileRecord]
    func stat(remote: RemotePath, serial: String) async throws -> RemoteFileRecord?
    /// Device-side sha256 of a file, when the toybox tooling is present.
    func remoteSHA256(remote: RemotePath, serial: String) async throws -> String?
    /// Pull a file into a staging DIRECTORY (caller-managed, must already
    /// exist). Returns the local file URL adb wrote inside it.
    func pull(remote: RemotePath, intoStagingDirectory: URL, serial: String) async throws -> URL
    /// Push a local file to a remote path.
    func push(localFile: URL, toRemote: RemotePath, serial: String) async throws
    /// Create a directory (mkdir -p).
    func makeDirectory(remote: RemotePath, serial: String) async throws
    /// `mv -n`: rename without clobbering. Explicit-upload publication only.
    func moveRemoteNoClobber(from: RemotePath, to: RemotePath, serial: String) async throws
    /// Remove a remote file. DeviceFileService restricts targets to
    /// app-owned temporary names; transports should still verify.
    func removeRemote(path: RemotePath, serial: String) async throws
    /// adb version string, for settings diagnostics.
    func version() async throws -> String
}
