// pattern: Imperative Shell
// Deterministic scenario services. Enabled ONLY via the explicit
// --ui-test-scenario launch argument; normal startup never touches these.

import BooxBridgeCore
import Foundation

enum ScenarioKind: String {
    case emptyLibrary
    case libraryWorkflow
    case deviceFiles
    case providerSettings
    case ocrConsent
}

struct ScenarioServices {
    let transport: ScenarioDeviceTransport
    let enrolledRoots: [ImportRoot]
    let serial: String
    let devicePhase: DevicePhase
    let initialActivity: [ActivityEvent]

    static func build(scenario: ScenarioKind, supportDirectory: URL) -> ScenarioServices {
        let serial = "78935a57"
        let root = try! RemotePath("/sdcard/note")
        let transport = ScenarioDeviceTransport()

        switch scenario {
        case .emptyLibrary:
            return ScenarioServices(
                transport: transport, enrolledRoots: [], serial: serial,
                devicePhase: .noDevice, initialActivity: [])
        case .libraryWorkflow:
            let seeded = seedLibrary(in: supportDirectory)
            _ = seeded
            return ScenarioServices(
                transport: transport,
                enrolledRoots: [ImportRoot(id: "r1", serial: serial, remoteRoot: root,
                                           displayName: "Notes", enrolledAt: Date())],
                serial: serial,
                devicePhase: .connected(serial, model: "Note Air 5C"),
                initialActivity: [ActivityEvent(date: Date(), title: "Import finished: Notes",
                                                detail: "1 new, 2 unchanged")])
        case .deviceFiles:
            transport.seedFiles([try! root.appending("test.pdf")])
            return ScenarioServices(
                transport: transport,
                enrolledRoots: [ImportRoot(id: "r1", serial: serial, remoteRoot: root,
                                           displayName: "Notes", enrolledAt: Date())],
                serial: serial,
                devicePhase: .connected(serial, model: "Note Air 5C"),
                initialActivity: [])
        case .providerSettings:
            return ScenarioServices(transport: transport, enrolledRoots: [], serial: serial,
                                    devicePhase: .noDevice, initialActivity: [])
        case .ocrConsent:
            return ScenarioServices(transport: transport, enrolledRoots: [], serial: serial,
                                    devicePhase: .noDevice, initialActivity: [])
        }
    }

    static func seedLibrary(in supportDirectory: URL) {
        // A tiny valid single-page PDF whose content is deterministic.
        let pdf = "%PDF-1.7\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 100]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF"
        let catalog = try? CatalogStore.open(atPath: supportDirectory.appendingPathComponent("catalog.sqlite").path)
        let storage = try? ManagedStorage(rootURL: supportDirectory.appendingPathComponent("library", isDirectory: true))
        guard let catalog, let storage else { return }
        let data = Data(pdf.utf8)
        let hash = SHA256Hasher().sha256Hex(of: data)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("scenario-\(hash).pdf")
        try? data.write(to: temp)
        _ = try? storage.commit(stagedFile: temp, contentSHA256: hash)
        let outcome = try? catalog.commitImport(
            key: DocumentKey(serial: "78935a57", rootID: "r1", relativePath: "scenario-note.pdf"),
            kind: .pdf, contentSHA256: hash, sizeBytes: Int64(data.count), pageCount: 1,
            remoteMtime: 1, remoteSize: Int64(data.count), at: Date(),
            title: "Scenario Note"
        )
        if case .newDocument(_, let revisionID)? = outcome {
            try? catalog.recordTranscription(revisionID: revisionID, pageIndex: 0,
                                             rawText: "scenario transcription sample", at: Date())
        }
    }
}

/// Fake device used only in scenario mode — a fixed file table, no process,
/// no network.
final class ScenarioDeviceTransport: DeviceTransport, @unchecked Sendable {
    let executableURL = URL(fileURLWithPath: "/nonexistent/scenario-adb")
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    private var directories: Set<String> = []

    func seedFiles(_ paths: [RemotePath]) {
        lock.lock(); defer { lock.unlock() }
        for path in paths {
            files[path.raw] = Data("%PDF-1.7 scenario".utf8)
        }
    }

    func listDevices() throws -> [DeviceEntry] {
        [DeviceEntry(serial: "78935a57", state: .device, isEmulator: false, isNetwork: false,
                     properties: ["model": "Note_Air_5C"])]
    }

    func deviceProperties(serial: String, names: [String]) throws -> [String: String] { [:] }

    func listFiles(root: RemotePath, serial: String) throws -> [RemoteFileRecord] {
        lock.lock(); defer { lock.unlock() }
        return files.keys
            .filter { $0.hasPrefix(root.raw + "/") }
            .map { RemoteFileRecord(path: try! RemotePath($0), sizeBytes: Int64(files[$0]!.count),
                                    modifiedEpochSeconds: 1, isRegularFile: true) }
            .sorted { $0.path.raw < $1.path.raw }
    }

    func listEntries(root: RemotePath, serial: String) throws -> [RemoteFileRecord] {
        listFiles(root: root, serial: serial)
    }

    func stat(remote: RemotePath, serial: String) throws -> RemoteFileRecord? {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[remote.raw] else { return nil }
        return RemoteFileRecord(path: remote, sizeBytes: Int64(data.count), modifiedEpochSeconds: 1, isRegularFile: true)
    }

    func remoteSHA256(remote: RemotePath, serial: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[remote.raw] else { return nil }
        return SHA256Hasher().sha256Hex(of: data)
    }

    func pull(remote: RemotePath, intoStagingDirectory: URL, serial: String) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard let data = files[remote.raw] else {
            throw AdbClientError.commandFailed(command: "pull", reason: "missing in scenario")
        }
        let destination = intoStagingDirectory.appendingPathComponent(remote.lastComponent)
        try data.write(to: destination)
        return destination
    }

    func push(localFile: URL, toRemote: RemotePath, serial: String) throws {
        try FileManager.default.contents(atPath: localFile.path).map { data in
            lock.lock(); defer { lock.unlock() }
            files[toRemote.raw] = data
        }
    }

    func makeDirectory(remote: RemotePath, serial: String) throws {
        lock.lock(); defer { lock.unlock() }
        directories.insert(remote.raw)
    }

    func moveRemoteNoClobber(from: RemotePath, to: RemotePath, serial: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard files[to.raw] == nil, let data = files.removeValue(forKey: from.raw) else { return }
        files[to.raw] = data
    }

    func removeRemote(path: RemotePath, serial: String) throws {
        guard RemoteTempName.isAppOwnedTemp(path.lastComponent) else { return }
        lock.lock(); defer { lock.unlock() }
        files.removeValue(forKey: path.raw)
    }

    func version() throws -> String { "scenario 1.0" }
}
