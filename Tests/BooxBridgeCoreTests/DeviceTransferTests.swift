import Foundation
import Testing
@testable import BooxBridgeCore

@Suite struct DeviceTransferTests {
    let root = try! RemotePath("/sdcard/note")

    func makeService(_ transport: FakeDeviceTransport) -> DeviceFileService {
        DeviceFileService(transport: transport, serial: "78935a57", browseRoot: root)
    }


    @Test func browsingListsDirectoriesFirstWithinRoot() async throws {
        let transport = FakeDeviceTransport()
        transport.seed(try root.appending("b.pdf"), data: Data("b".utf8))
        transport.seed(try root.appending("sub").appending("a.pdf"), data: Data("a".utf8))
        try transport.makeDirectory(remote: try root.appending("sub"), serial: "s")

        let service = makeService(transport)
        let entries = try await service.entries(in: root)
        #expect(entries.count == 2)
        #expect(entries[0].isDirectory && entries[0].name == "sub")
        #expect(!entries[1].isDirectory && entries[1].name == "b.pdf")

        let nested = try await service.entries(in: try root.appending("sub"))
        #expect(nested.map(\.name) == ["a.pdf"])
    }

    @Test func operationsOutsideBrowseRootAreRejected() async throws {
        let transport = FakeDeviceTransport()
        let service = makeService(transport)
        let outside = try RemotePath("/sdcard/other")
        await #expect(throws: DeviceFileError.self) {
            _ = try await service.entries(in: outside)
        }
        await #expect(throws: DeviceFileError.self) {
            try await service.createFolder(named: "x", in: outside)
        }
        try await withTempDirectoryAsync { dir in
            let local = dir.appendingPathComponent("f.txt")
            try Data("x".utf8).write(to: local)
            await #expect(throws: DeviceFileError.self) {
                try await service.upload(localFile: local, toDirectory: outside, overwrite: false)
            }
            await #expect(throws: DeviceFileError.self) {
                _ = try await service.download(files: [outside.appending("f.txt")], intoLocalDirectory: dir, overwrite: false)
            }
        }
    }

    @Test func downloadStagesThenMovesAndHonorsConsent() async throws {
        let transport = FakeDeviceTransport()
        transport.seed(try root.appending("export.pdf"), data: Data("%PDF-1.7 test".utf8))
        let service = makeService(transport)

        try await withTempDirectoryAsync { dir in
            let written = try await service.download(
                files: [try root.appending("export.pdf")], intoLocalDirectory: dir, overwrite: false
            )
            #expect(written.count == 1)
            #expect(try String(contentsOf: written[0], encoding: .utf8) == "%PDF-1.7 test")

            try Data("existing".utf8).write(to: written[0])
            await #expect(throws: DeviceFileError.self) {
                _ = try await service.download(files: [try root.appending("export.pdf")], intoLocalDirectory: dir, overwrite: false)
            }
            #expect(try String(contentsOf: written[0], encoding: .utf8) == "existing")

            _ = try await service.download(files: [try root.appending("export.pdf")], intoLocalDirectory: dir, overwrite: true)
            #expect(try String(contentsOf: written[0], encoding: .utf8) == "%PDF-1.7 test")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".booxbridge-download-") }
            #expect(leftovers.isEmpty)
        }
    }

    /// Regression test for the mid-flight overwrite race: the only consent
    /// check used to run BEFORE the pull, and publication then removed
    /// (recursively) and replaced whatever had appeared in the meantime —
    /// destroying bytes the consent decision never saw. A destination that
    /// materializes while the pull is in flight must produce a conflict,
    /// with its bytes untouched.
    @Test func downloadConflictsWhenDestinationAppearsMidFlight() async throws {
        let transport = FakeDeviceTransport()
        let remote = try root.appending("export.pdf")
        transport.seed(remote, data: Data("%PDF-1.7 test".utf8))
        let service = makeService(transport)

        try await withTempDirectoryAsync { dir in
            let destination = dir.appendingPathComponent("export.pdf")
            let competitor = Data("mid-flight original".utf8)
            transport.onPull = { _ in
                try? competitor.write(to: destination)
            }
            await #expect(throws: DeviceFileError.destinationExistsNeedsConfirmation(path: destination.lastPathComponent)) {
                _ = try await service.download(files: [remote], intoLocalDirectory: dir, overwrite: false)
            }
            // The mid-flight file's bytes are exactly as the other writer
            // left them — not the staged download content.
            #expect(try Data(contentsOf: destination) == competitor)
            // Staging is cleaned up; no orphaned download directories.
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix(".booxbridge-download-") }
            #expect(leftovers.isEmpty)
        }
    }

    /// With explicit consent, a destination that appears mid-flight is
    /// replaced — atomically, so publication cannot expose a half-state.
    @Test func downloadOverwriteReplacesDestinationAppearedMidFlight() async throws {
        let transport = FakeDeviceTransport()
        let remote = try root.appending("export.pdf")
        transport.seed(remote, data: Data("%PDF-1.7 test".utf8))
        let service = makeService(transport)

        try await withTempDirectoryAsync { dir in
            let destination = dir.appendingPathComponent("export.pdf")
            transport.onPull = { _ in
                try? Data("mid-flight original".utf8).write(to: destination)
            }
            let written = try await service.download(files: [remote], intoLocalDirectory: dir, overwrite: true)
            #expect(written == [destination])
            #expect(try Data(contentsOf: destination) == Data("%PDF-1.7 test".utf8))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix(".booxbridge-download-") }
            #expect(leftovers.isEmpty)
        }
    }

    /// A failed overwrite publication must preserve the existing
    /// destination byte-for-byte: rename(2) refuses to replace a directory
    /// with a file, and the previous remove-then-move would have deleted
    /// that directory (recursively) before failing. The directory created
    /// mid-flight here survives with its contents.
    @Test func failedOverwritePublicationPreservesExistingDestination() async throws {
        let transport = FakeDeviceTransport()
        let remote = try root.appending("export.pdf")
        transport.seed(remote, data: Data("%PDF-1.7 test".utf8))
        let service = makeService(transport)

        try await withTempDirectoryAsync { dir in
            let destination = dir.appendingPathComponent("export.pdf")
            let keep = destination.appendingPathComponent("keep.txt")
            transport.onPull = { _ in
                try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try? Data("inside".utf8).write(to: keep)
            }
            await #expect(throws: POSIXError.self) {
                _ = try await service.download(files: [remote], intoLocalDirectory: dir, overwrite: true)
            }
            #expect(FileManager.default.fileExists(atPath: keep.path))
            #expect(try Data(contentsOf: keep) == Data("inside".utf8))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasPrefix(".booxbridge-download-") }
            #expect(leftovers.isEmpty)
        }
    }

    @Test func uploadStagesUnderTempAndPublishesVerified() async throws {
        let transport = FakeDeviceTransport()
        let service = makeService(transport)

        try await withTempDirectoryAsync { dir in
            let local = dir.appendingPathComponent("notes.txt")
            try Data("hello device".utf8).write(to: local)
            try await service.upload(localFile: local, toDirectory: root, overwrite: false)

            let files = transport.snapshotFiles()
            #expect(files[try root.appending("notes.txt").raw] != nil)
            #expect(try Data(contentsOf: local) == files[try root.appending("notes.txt").raw]!.data)
            #expect(files.keys.filter { RemoteTempName.isAppOwnedTemp(($0 as NSString).lastPathComponent) }.isEmpty)
        }
    }

    @Test func uploadToExistingRemoteNameRequiresUserAction() async throws {
        let transport = FakeDeviceTransport()
        transport.seed(try root.appending("notes.txt"), data: Data("old".utf8))
        let service = makeService(transport)

        try await withTempDirectoryAsync { dir in
            let local = dir.appendingPathComponent("notes.txt")
            try Data("new".utf8).write(to: local)
            // Remote overwrite needs a separate device-side action, even when the user permits local overwrite.
            await #expect(throws: DeviceFileError.destinationExistsNeedsConfirmation(path: try root.appending("notes.txt").raw)) {
                try await service.upload(localFile: local, toDirectory: root, overwrite: true)
            }
            #expect(transport.snapshotFiles()[try root.appending("notes.txt").raw]!.data == Data("old".utf8))
            #expect(transport.movedRemote.isEmpty && transport.removedRemote.isEmpty)
        }
    }


    @Test func publishRaceAbortsAndCleansTempOnly() async throws {
        let transport = FakeDeviceTransport()
        let service = makeService(transport)
        let destination = try root.appending("raced.txt")
        transport.raceWriter = { path in
            transport.seed(path, data: Data("concurrent writer".utf8))
        }

        try await withTempDirectoryAsync { dir in
            let local = dir.appendingPathComponent("raced.txt")
            try Data("our upload".utf8).write(to: local)
            await #expect(throws: DeviceFileError.publishRace(path: destination.raw)) {
                try await service.upload(localFile: local, toDirectory: root, overwrite: false)
            }
        }
        #expect(transport.snapshotFiles()[destination.raw]!.data == Data("concurrent writer".utf8))
        #expect(transport.removedRemote.allSatisfy { RemoteTempName.isAppOwnedTemp(($0 as NSString).lastPathComponent) })
        #expect(transport.removedRemote.count == 1)
    }

    @Test func disconnectDuringUploadPreservesDeviceStateAndCleansTemp() async throws {
        let transport = FakeDeviceTransport()
        transport.failPush = true
        let service = makeService(transport)

        try await withTempDirectoryAsync { dir in
            let local = dir.appendingPathComponent("upload.txt")
            try Data("partial".utf8).write(to: local)
            await #expect(throws: AdbClientError.self) {
                try await service.upload(localFile: local, toDirectory: root, overwrite: false)
            }
        }
        #expect(transport.snapshotFiles().isEmpty || transport.snapshotFiles().keys.allSatisfy {
            RemoteTempName.isAppOwnedTemp(($0 as NSString).lastPathComponent)
        })
        #expect(transport.removedRemote.allSatisfy { RemoteTempName.isAppOwnedTemp(($0 as NSString).lastPathComponent) })
    }


    @Test func importsNeverIssueRemoteMutations() async throws {
        let transport = FakeDeviceTransport()
        transport.seed(try root.appending("a.pdf"), data: Data("%PDF-1.7 x".utf8), mtime: 5)
        transport.seed(try root.appending("b.pdf"), data: Data("%PDF-1.7 y".utf8), mtime: 6)

        try await withTempDirectoryAsync { dir in
            let catalog = try CatalogStore.open(atPath: dir.appendingPathComponent("c.sqlite").path)
            let storage = try ManagedStorage(rootURL: dir.appendingPathComponent("lib", isDirectory: true))
            let importer = DeviceImportService(
                transport: transport, catalog: catalog, storage: storage,
                hasher: SHA256Hasher(), validator: SniffingValidator(), clock: ManualClock()
            )
            _ = try await importer.sync(root: ImportRoot(
                id: "r", serial: "78935a57", remoteRoot: root, displayName: "Notes", enrolledAt: Date()
            ))
            transport.failListing = true
            _ = try? await importer.sync(root: ImportRoot(
                id: "r", serial: "78935a57", remoteRoot: root, displayName: "Notes", enrolledAt: Date()
            ))
        }
        #expect(transport.movedRemote.isEmpty)
        #expect(transport.removedRemote.isEmpty)
    }

    @Test func adbClientRefusesToRemoveNonTempRemoteNames() async throws {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("boox-fake-adb-\(UUID().uuidString).sh")
        try "#!/bin/sh\nexit 0\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let client = try AdbClient(executableURL: script)
        let innocent = try root.appending("important.pdf")
        await #expect(throws: AdbClientError.self) {
            try await client.removeRemote(path: innocent, serial: "78935a57")
        }
        for command in [AdbCommand.devices, .version,
                        .listFiles(root: root, serial: "s"),
                        .stat(remote: innocent, serial: "s"),
                        .sha256(remote: innocent, serial: "s"),
                        .pull(remote: innocent, intoLocalDirectory: "/tmp", serial: "s")] {
            let argv = AdbCommandBuilder.argv(for: command).joined(separator: " ")
            #expect(!argv.contains(" rm "), "import command must not remove: \(argv)")
            #expect(!argv.contains(" mv "), "import command must not rename: \(argv)")
        }
    }

    @Test func createFolderIsValidated() async throws {
        let transport = FakeDeviceTransport()
        let service = makeService(transport)
        try await service.createFolder(named: "New Folder", in: root)
        let entries = try await service.entries(in: root)
        #expect(entries.first?.name == "New Folder" && entries.first?.isDirectory == true)

        await #expect(throws: DeviceFileError.invalidName("..")) {
            try await service.createFolder(named: "..", in: root)
        }
        await #expect(throws: DeviceFileError.invalidName("a/b")) {
            try await service.createFolder(named: "a/b", in: root)
        }
    }

    /// Regression test for the upload path on a REAL AdbClient: the earlier
    /// dispatch layer threw for every nonzero exit, so upload's first stat
    /// (existence check) aborted every normal NEW-filename upload on a real
    /// device, where stat answers exit 1 + ENOENT for an absent file. The
    /// scripted adb here models the device filesystem as a host directory
    /// and speaks the exact argv shapes AdbCommandBuilder emits.
    @Test func uploadPublishesNewFileThroughRealAdbClient() async throws {
        try await withTempDirectoryAsync { dir in
            let deviceRoot = dir.appendingPathComponent("device", isDirectory: true)
            try FileManager.default.createDirectory(at: deviceRoot, withIntermediateDirectories: true)
            let script = dir.appendingPathComponent("adb-emulator.sh")
            let quotedRoot = "'" + deviceRoot.path + "'"
            let body = """
            #!/bin/sh
            # Minimal adb emulator backed by a host directory (ROOT maps the
            # device filesystem root). adb passes a shell command as ONE
            # argument, so parse the command line. Supported shapes:
            #   shell stat -c '%s|%Y|%F' -- 'PATH'
            #   push LOCAL REMOTE
            #   shell mv -n -- 'FROM' 'TO'
            #   shell rm -f -- 'PATH'
            #   shell sha256sum -- 'PATH'
            ROOT=\(quotedRoot)
            if [ "$1" = "-s" ]; then shift 2; fi
            sub="$1"; shift
            if [ "$sub" = "push" ]; then
              mkdir -p "$ROOT$(dirname "$2")"
              cp "$1" "$ROOT$2"
              exit $?
            fi
            if [ "$sub" = "shell" ]; then
              cmdline="$1"
              case "$cmdline" in
                stat*)
                  path=$(printf '%s' "$cmdline" | sed -e "s/^.*-- '//" -e "s/'$//")
                  f="$ROOT$path"
                  if [ -e "$f" ]; then
                    if [ -d "$f" ]; then kind="directory"; else kind="regular file"; fi
                    printf '%s|1000|%s\\n' "$(wc -c < "$f" | tr -d ' ')" "$kind"
                    exit 0
                  fi
                  printf "stat: '%s': No such file or directory\\n" "$path" >&2
                  exit 1 ;;
                mv*)
                  from=$(printf '%s' "$cmdline" | sed -e "s/^mv -n -- '//" -e "s/'.*//")
                  to=$(printf '%s' "$cmdline" | sed -e "s/^.* '//" -e "s/'$//")
                  if [ -e "$ROOT$to" ]; then
                    exit 0  # mv -n silently skips an existing destination
                  fi
                  mv "$ROOT$from" "$ROOT$to"
                  exit $? ;;
                rm*)
                  path=$(printf '%s' "$cmdline" | sed -e "s/^rm -f -- '//" -e "s/'$//")
                  rm -f "$ROOT$path"
                  exit $? ;;
                sha256sum*)
                  path=$(printf '%s' "$cmdline" | sed -e "s/^sha256sum -- '//" -e "s/'$//")
                  f="$ROOT$path"
                  if [ -f "$f" ] && command -v sha256sum >/dev/null 2>&1; then
                    printf '%s  %s\\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$path"
                    exit 0
                  fi
                  printf "sha256sum: %s: No such file or directory\\n" "$path" >&2
                  exit 1 ;;
              esac
            fi
            echo "unhandled argv: $*" >&2
            exit 64
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

            let client = try AdbClient(executableURL: script)
            let service = DeviceFileService(transport: client, serial: "78935a57", browseRoot: root)
            let local = dir.appendingPathComponent("notes.txt")
            let expected = Data("hello real device".utf8)
            try expected.write(to: local)

            try await service.upload(localFile: local, toDirectory: root, overwrite: false)

            let publishedPath = deviceRoot.appendingPathComponent("sdcard/note/notes.txt").path
            #expect(FileManager.default.fileExists(atPath: publishedPath))
            #expect(try Data(contentsOf: URL(fileURLWithPath: publishedPath)) == expected)
            // The upload temp must have been consumed by the publish move.
            let publishedDir = deviceRoot.appendingPathComponent("sdcard/note").path
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: publishedDir)
            #expect(leftovers == ["notes.txt"])
        }
    }
}
