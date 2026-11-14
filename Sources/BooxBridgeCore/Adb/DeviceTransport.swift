// pattern: Imperative Shell
// Device transport seam. AdbClient is the production implementation; tests
// and deterministic UI scenarios substitute fakes behind this protocol.

import Foundation

public protocol DeviceTransport: Sendable {
    /// Path of the adb executable this transport runs (for diagnostics).
    var executableURL: URL { get }

    func listDevices() async throws -> [DeviceEntry]
    func deviceProperties(serial: String, names: [String]) async throws -> [String: String]
    /// Regular files under `root`, NUL-delimited listing. Throws on any
    /// malformed record — never fabricates an empty-but-successful listing.
    func listFiles(root: RemotePath, serial: String) async throws -> [RemoteFileRecord]
    func stat(remote: RemotePath, serial: String) async throws -> RemoteFileRecord?
    /// Device-side sha256 of a file, when the toybox tooling is present.
    func remoteSHA256(remote: RemotePath, serial: String) async throws -> String?
    /// Pull a file into a staging DIRECTORY (caller-managed, must already
    /// exist). Returns the local file URL adb wrote inside it.
    func pull(remote: RemotePath, intoStagingDirectory: URL, serial: String) async throws -> URL
    /// Push a local file to a remote path.
    func push(localFile: URL, toRemote: RemotePath, serial: String) async throws
    /// Create a directory (mkdir -p). No other remote mutations exist.
    func makeDirectory(remote: RemotePath, serial: String) async throws
    /// adb version string, for settings diagnostics.
    func version() async throws -> String
}
