// pattern: Imperative Shell
// ADBClient wraps a user-selected adb executable. Every command goes
// through AdbCommandBuilder (pure argv construction) and the injected
// ProcessRunning seam. The executable URL is validated at construction:
// it must exist, be a regular file, and be executable. No server
// start/kill commands are ever issued — adb manages its own daemon.

import Foundation

public enum AdbClientError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidExecutable(String)
    case commandFailed(command: String, reason: String)
    case outputUnparsable(command: String, detail: String)
    case missingCapability(String)

    public var description: String {
        switch self {
        case .invalidExecutable(let path): return "adb executable is missing or not executable: \(path)"
        case .commandFailed(let command, let reason): return "adb \(command) failed: \(reason)"
        case .outputUnparsable(let command, let detail): return "adb \(command) produced unparsable output: \(detail)"
        case .missingCapability(let what): return "device tooling lacks required capability: \(what)"
        }
    }
}

public actor AdbClient: DeviceTransport {
    public nonisolated let executableURL: URL
    private let runner: ProcessRunning
    private let defaultTimeout: TimeInterval

    public init(executableURL: URL, runner: ProcessRunning = FoundationProcessRunner(), timeout: TimeInterval = 120) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = fm.fileExists(atPath: executableURL.path, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue, fm.isExecutableFile(atPath: executableURL.path) else {
            throw AdbClientError.invalidExecutable(executableURL.path)
        }
        self.executableURL = executableURL
        self.runner = runner
        self.defaultTimeout = timeout
    }

    /// Discovery suggestions for Settings — conventional install locations,
    /// never executed, never from shell profile parsing.
    static func suggestedExecutableURLs() -> [URL] {
        let candidates = [
            "/usr/local/bin/adb", "/opt/homebrew/bin/adb", "/usr/bin/adb",
            "~/Library/Android/sdk/platform-tools/adb",
            "~/Android/Sdk/platform-tools/adb",
        ]
        return candidates.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }

    public func version() async throws -> String {
        let result = try await dispatch(.version)
        return String(data: result.stdout, encoding: .utf8)?
            .split(separator: "\n").first.map(String.init) ?? ""
    }

    public func listDevices() async throws -> [DeviceEntry] {
        let result = try await dispatch(.devices)
        let text = String(data: result.stdout, encoding: .utf8) ?? ""
        return DeviceListParser.parse(text)
    }

    public func deviceProperties(serial: String, names: [String]) async throws -> [String: String] {
        var values: [String: String] = [:]
        for name in names {
            let result = try await dispatch(.deviceProperty(name: name, serial: serial))
            let raw = String(data: result.stdout, encoding: .utf8) ?? ""
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { values[name] = trimmed }
        }
        return values
    }

    public func listFiles(root: RemotePath, serial: String) async throws -> [RemoteFileRecord] {
        let result = try await dispatch(.listFiles(root: root, serial: serial))
        guard result.succeeded else {
            // A failed listing must surface, never be read as "no files".
            throw AdbClientError.commandFailed(command: "find \(root)", reason: stderrSummary(result))
        }
        return try RemoteListingParser.parse(result.stdout, root: root)
    }

    public func listEntries(root: RemotePath, serial: String) async throws -> [RemoteFileRecord] {
        let result = try await dispatch(.listEntries(root: root, serial: serial))
        guard result.succeeded else {
            throw AdbClientError.commandFailed(command: "find \(root)", reason: stderrSummary(result))
        }
        return try RemoteListingParser.parse(result.stdout, root: root, includingDirectories: true)
    }

    public func stat(remote: RemotePath, serial: String) async throws -> RemoteFileRecord? {
        let result = try await dispatch(.stat(remote: remote, serial: serial))
        guard result.succeeded else { return nil }
        let line = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !line.isEmpty else { return nil }
        let fields = line.split(separator: "|", omittingEmptySubsequences: false)
        guard fields.count == 3, let size = Int64(fields[0]), let mtime = Int64(fields[1]) else {
            throw AdbClientError.outputUnparsable(command: "stat", detail: line)
        }
        return RemoteFileRecord(path: remote, sizeBytes: size, modifiedEpochSeconds: mtime,
                                isRegularFile: String(fields[2]).contains("regular file"))
    }

    public func remoteSHA256(remote: RemotePath, serial: String) async throws -> String? {
        let result = try await dispatch(.sha256(remote: remote, serial: serial))
        guard result.succeeded else { return nil }
        let line = String(data: result.stdout, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hash = line.split(separator: " ").first.map(String.init) ?? ""
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { return nil }
        return hash.lowercased()
    }

    public func pull(remote: RemotePath, intoStagingDirectory: URL, serial: String) async throws -> URL {
        let stagingPath = intoStagingDirectory.path
        let result = try await dispatch(.pull(remote: remote, intoLocalDirectory: stagingPath, serial: serial))
        guard result.succeeded else {
            throw AdbClientError.commandFailed(command: "pull \(remote)", reason: stderrSummary(result))
        }
        // adb writes the file under the staging directory using the remote
        // basename. RemotePath components can never be ".", "..", or contain
        // "/", so the join is safe by construction; verify existence anyway.
        let localURL = intoStagingDirectory.appendingPathComponent(remote.lastComponent)
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw AdbClientError.outputUnparsable(command: "pull", detail: "expected staged file missing: \(localURL.path)")
        }
        return localURL
    }

    public func push(localFile: URL, toRemote: RemotePath, serial: String) async throws {
        let result = try await dispatch(.push(localPath: localFile.path, toRemote: toRemote, serial: serial))
        guard result.succeeded else {
            throw AdbClientError.commandFailed(command: "push \(toRemote)", reason: stderrSummary(result))
        }
    }

    public func makeDirectory(remote: RemotePath, serial: String) async throws {
        let result = try await dispatch(.makeDirectory(remote: remote, serial: serial))
        guard result.succeeded else {
            throw AdbClientError.commandFailed(command: "mkdir \(remote)", reason: stderrSummary(result))
        }
    }

    public func moveRemoteNoClobber(from: RemotePath, to: RemotePath, serial: String) async throws {
        let result = try await dispatch(.moveRemoteNoClobber(from: from, to: to, serial: serial))
        guard result.succeeded else {
            throw AdbClientError.commandFailed(command: "mv \(from) → \(to)", reason: stderrSummary(result))
        }
    }

    public func removeRemote(path: RemotePath, serial: String) async throws {
        guard RemoteTempName.isAppOwnedTemp(path.lastComponent) else {
            throw AdbClientError.commandFailed(
                command: "rm",
                reason: "refusing to remove non-temporary remote name \(path.raw)"
            )
        }
        let result = try await dispatch(.removeRemote(path: path, serial: serial))
        guard result.succeeded else {
            throw AdbClientError.commandFailed(command: "rm \(path)", reason: stderrSummary(result))
        }
    }

    // MARK: - Internals

    private func dispatch(_ command: AdbCommand) async throws -> ProcessResult {
        let request = ProcessRequest(
            executable: executableURL,
            arguments: AdbCommandBuilder.argv(for: command),
            timeout: timeout(for: command)
        )
        let result: ProcessResult
        do {
            result = try await runner.run(request)
        } catch let failure as ProcessFailure {
            throw AdbClientError.commandFailed(
                command: String(describing: command),
                reason: String(describing: failure)
            )
        }
        guard result.succeeded else {
            throw AdbClientError.commandFailed(
                command: label(for: command),
                reason: stderrSummary(result)
            )
        }
        return result
    }

    private func timeout(for command: AdbCommand) -> TimeInterval {
        switch command {
        case .pull, .push: return max(defaultTimeout, 600)
        default: return defaultTimeout
        }
    }

    private func label(for command: AdbCommand) -> String {
        switch command {
        case .version: return "version"
        case .devices: return "devices"
        case .stat: return "stat"
        case .sha256: return "sha256sum"
        case .listFiles: return "find"
        case .listEntries: return "find"
        case .pull: return "pull"
        case .push: return "push"
        case .makeDirectory: return "mkdir"
        case .deviceProperty: return "getprop"
        case .moveRemoteNoClobber: return "mv"
        case .removeRemote: return "rm"
        }
    }

    private func stderrSummary(_ result: ProcessResult) -> String {
        let text = String(data: result.stderr, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(text.prefix(300))
    }
}
