// Test fixtures: an in-memory DeviceTransport over a temp catalog so import
// integration runs without a device or adb.
import Foundation
@testable import BooxBridgeCore

final class FakeDeviceTransport: DeviceTransport, @unchecked Sendable {
    let executableURL = URL(fileURLWithPath: "/nonexistent/adb")

    struct FakeFile {
        var data: Data
        var sizeBytes: Int64 { Int64(data.count) }
        var mtime: Int64
    }

    private let lock = NSLock()
    private var files: [String: FakeFile] = [:]
    private var statCounts: [String: Int] = [:]
    private(set) var listCalls = 0
    private(set) var pullCalls = 0

    /// When true, the post-pull stat reports a different size — simulating a
    /// file still being written by the device's export process.
    var mutateOnPostStat = false
    /// When true, remoteSHA256 returns a bogus hash — simulating corruption.
    var corruptRemoteHash = false
    /// When true, listFiles throws — simulating a disconnect mid-sync.
    var failListing = false

    func seed(_ path: RemotePath, data: Data, mtime: Int64 = 1_000) {
        lock.lock(); defer { lock.unlock() }
        files[path.raw] = FakeFile(data: data, mtime: mtime)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        files.removeAll()
    }

    func update(_ path: RemotePath, data: Data, mtime: Int64) {
        lock.lock(); defer { lock.unlock() }
        files[path.raw] = FakeFile(data: data, mtime: mtime)
    }

    func snapshotFiles() -> [String: FakeFile] {
        lock.lock(); defer { lock.unlock() }
        return files
    }

    private func file(_ path: String) -> FakeFile? {
        lock.lock(); defer { lock.unlock() }
        return files[path]
    }

    func listFiles(root: RemotePath, serial: String) throws -> [RemoteFileRecord] {
        lock.lock(); defer { lock.unlock() }
        listCalls += 1
        if failListing { throw AdbClientError.commandFailed(command: "find", reason: "device disconnected") }
        return files
            .filter { $0.key.hasPrefix(root.raw + "/") }
            .map { key, value in
                RemoteFileRecord(
                    path: try! RemotePath(key),
                    sizeBytes: value.sizeBytes,
                    modifiedEpochSeconds: value.mtime,
                    isRegularFile: true
                )
            }
            .sorted { $0.path.raw < $1.path.raw }
    }

    func stat(remote: RemotePath, serial: String) throws -> RemoteFileRecord? {
        guard let f = file(remote.raw) else { return nil }
        lock.lock()
        statCounts[remote.raw, default: 0] += 1
        let callNumber = statCounts[remote.raw]!
        lock.unlock()
        // Mutate only on EVEN stat calls for a path (the 2nd, 4th, …): the
        // importer stats pre- and post-pull, so the "post" observation is
        // the one that must differ when instability is being simulated.
        let mutated = mutateOnPostStat && callNumber % 2 == 0
        let size = mutated ? f.sizeBytes + 7 : f.sizeBytes
        return RemoteFileRecord(path: remote, sizeBytes: size, modifiedEpochSeconds: f.mtime, isRegularFile: true)
    }

    func remoteSHA256(remote: RemotePath, serial: String) throws -> String? {
        if corruptRemoteHash { return String(repeating: "0", count: 64) }
        guard let f = file(remote.raw) else { return nil }
        return SHA256Hasher().sha256Hex(of: f.data)
    }

    func pull(remote: RemotePath, intoStagingDirectory: URL, serial: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        pullCalls += 1
        guard let f = files[remote.raw] else {
            throw AdbClientError.commandFailed(command: "pull", reason: "no such file")
        }
        let destination = intoStagingDirectory.appendingPathComponent(remote.lastComponent)
        try f.data.write(to: destination)
        return destination
    }

    func push(localFile: URL, toRemote: RemotePath, serial: String) throws {
        let data = try Data(contentsOf: localFile)
        lock.lock(); defer { lock.unlock() }
        files[toRemote.raw] = FakeFile(data: data, mtime: 9_999)
    }

    func makeDirectory(remote: RemotePath, serial: String) throws {}

    func listDevices() throws -> [DeviceEntry] { [] }
    func deviceProperties(serial: String, names: [String]) throws -> [String: String] { [:] }
    func version() throws -> String { "fake 1.0" }
}

@discardableResult
func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("boox-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try body(url)
}

@discardableResult
func withTempDirectoryAsync<T>(_ body: (URL) async throws -> T) async throws -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("boox-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}
