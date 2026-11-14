import Foundation
import Testing
@testable import BooxBridgeCore

@Suite struct RemotePathSafetyTests {
    @Test func rejectsTraversalAndRelativePaths() {
        #expect(throws: RemotePathError.self) { try RemotePath("../etc/passwd") }
        #expect(throws: RemotePathError.self) { try RemotePath("/sdcard/note/../../secret") }
        #expect(throws: RemotePathError.self) { try RemotePath("sdcard/note") }
        #expect(throws: RemotePathError.self) { try RemotePath("") }
        #expect(throws: RemotePathError.nulByte("/sdcard/note\u{0}")) { try RemotePath("/sdcard/note\u{0}") }
        #expect(throws: RemotePathError.self) { try RemotePath("/") }
        // Newlines are legal filename bytes: parsed, quoted, and round-tripped.
        #expect(throws: Never.self) { _ = try RemotePath("/sdcard/no\nte") }
    }

    @Test func normalizesAndCompares() throws {
        let root = try RemotePath("/sdcard/note")
        #expect(throws: RemotePathError.traversalComponent("/sdcard/note/sub/../test.pdf")) {
            _ = try RemotePath("/sdcard/note/sub/../test.pdf")
        }
        #expect(root.raw == "/sdcard/note")
        let child = try root.appending("te st.pdf")
        #expect(child.raw == "/sdcard/note/te st.pdf")
        #expect(child.isWithin(root))
        #expect(try! RemotePath("/sdcard/other").isWithin(root) == false)
        #expect(throws: RemotePathError.self) {
            try child.requireWithin(try RemotePath("/sdcard/other"))
        }
        #expect(throws: RemotePathError.self) { try root.appending("..") }
        #expect(throws: RemotePathError.self) { try root.appending("a/b") }
    }

    @Test func quotingSurvivesHostileFilenames() {
        let hostile = "it's ; rm -rf /; $(reboot) `echo x` |xargs sh"
        let quoted = ShellQuoting.quote(hostile)
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        #expect(quoted == "'it'\\''s ; rm -rf /; $(reboot) `echo x` |xargs sh'")
        #expect(ShellQuoting.quote("plain") == "'plain'")
        #expect(ShellQuoting.quote("üñí çø∂é.pdf") == "'üñí çø∂é.pdf'")
    }

    @Test func argvNeverGoesThroughAShellLocally() {
        let argv = AdbCommandBuilder.argv(for: .stat(remote: try! RemotePath("/sdcard/note/a b'.pdf"), serial: "78935a57"))
        #expect(argv.contains("-s"))
        #expect(argv.contains("78935a57"))
        let script = argv.first { $0.hasPrefix("stat") }!
        #expect(script.contains("'/sdcard/note/a b'\\''.pdf'"))
    }

    @Test func listingScriptQuotesRootAndHandlesHyphens() throws {
        let root = try RemotePath("/sdcard/note")
        let script = AdbCommandBuilder.listingScript(for: root)
        #expect(script.contains("find '/sdcard/note' -type f"))
        #expect(script.contains("sh -c"))
        #expect(script.contains("-- \"$f\""))
        #expect(script.contains("printf \"%s\\0\" \"$f\""))
    }

    @Test func listingParserHandlesHostileRecords() throws {
        func record(_ meta: String, _ name: String) -> Data {
            Data("\(meta)\t\(name)".utf8 + [0])
        }
        let root = try RemotePath("/sdcard/note")
        var data = Data()
        data.append(record("100|1000|regular file", "/sdcard/note/plain.pdf"))
        data.append(record("7|2000|regular file", "/sdcard/note/ünï çø∂é \"quoted\".pdf"))
        data.append(record("9|3000|regular file", "/sdcard/note/-leading-hyphen.png"))
        data.append(record("8|4000|regular file", "/sdcard/note/new\nline.jpg"))
        data.append(record("5|5000|regular file", "/sdcard/note/tab\tinside.pdf"))
        data.append(record("0|6000|directory", "/sdcard/note/subdir"))
        let parsed = try RemoteListingParser.parse(data, root: root)
        #expect(parsed.count == 5)
        #expect(parsed.allSatisfy { $0.isRegularFile })
        #expect(parsed.contains { $0.path.lastComponent == "new\nline.jpg" })
        #expect(parsed.contains { $0.path.lastComponent == "tab\tinside.pdf" })
        #expect(parsed.contains { $0.path.lastComponent == "-leading-hyphen.png" })
    }

    @Test func listingParserRejectsAmbiguityAndTruncation() throws {
        let root = try RemotePath("/sdcard/note")
        #expect(throws: RemoteListingParser.ParseError.self) {
            _ = try RemoteListingParser.parse(Data("garbage".utf8 + [0]), root: root)
        }
        #expect(throws: RemoteListingParser.ParseError.truncatedListing) {
            _ = try RemoteListingParser.parse(Data("1|1|regular file\t/sdcard/note/a.pdf".utf8), root: root)
        }
        #expect(throws: RemoteListingParser.ParseError.self) {
            _ = try RemoteListingParser.parse(Data("1|1|regular file\t/sdcard/other/x".utf8 + [0]), root: root)
        }
    }
}

@Suite struct AdbDiscoveryTests {
    let sample = """
    List of devices attached
    78935a57               device usb:1-3 product:NoteAir5C model:Note_Air_5C device:tahoe transport_id:4
    emulator-5554          device transport_id:1
    192.168.1.42:5555      device transport_id:2
    ABC123                 unauthorized usb:1-2 transport_id:5
    XYZ999                 offline transport_id:6
    * daemon not running; starting now at tcp:5037
    * daemon started successfully

    """


    @Test func parsesStatesTransportsAndProperties() {
        let devices = DeviceListParser.parse(sample)
        #expect(devices.count == 5)
        let usb = devices.first { $0.serial == "78935a57" }!
        #expect(usb.state == .device)
        #expect(usb.isEmulator == false)
        #expect(usb.isNetwork == false)
        #expect(usb.properties["model"] == "Note_Air_5C")
        #expect(usb.displayName.contains("Note Air 5C"))
        #expect(devices.first { $0.serial == "emulator-5554" }!.isEmulator)
        #expect(devices.first { $0.serial == "192.168.1.42:5555" }!.isNetwork)
        #expect(devices.first { $0.serial == "ABC123" }!.state == .unauthorized)
        #expect(devices.first { $0.serial == "XYZ999" }!.state == .offline)
    }

    @Test func usbCandidateSelectionScenarios() {
        let ready = DeviceEntry(serial: "78935a57", state: .device, isEmulator: false, isNetwork: false, properties: [:])
        let emulator = DeviceEntry(serial: "emulator-5554", state: .device, isEmulator: true, isNetwork: false, properties: [:])
        let network = DeviceEntry(serial: "10.0.0.5:5555", state: .device, isEmulator: false, isNetwork: true, properties: [:])
        let unauthorized = DeviceEntry(serial: "U1", state: .unauthorized, isEmulator: false, isNetwork: false, properties: [:])
        let offline = DeviceEntry(serial: "O1", state: .offline, isEmulator: false, isNetwork: false, properties: [:])

        if case .single(let pick) = DeviceListParser.usbCandidate([ready, emulator, network]) {
            #expect(pick.serial == "78935a57")
        } else { Issue.record("expected single USB candidate") }

        if case .ambiguous(let options) = DeviceListParser.usbCandidate([ready, DeviceEntry(serial: "ZZZ", state: .device, isEmulator: false, isNetwork: false, properties: [:])]) {
            #expect(options.count == 2)
        } else { Issue.record("expected ambiguous selection") }
        #expect(DeviceListParser.usbCandidate([ready, emulator]).requiresUserChoice == false)

        if case .needsAuthorization(let d) = DeviceListParser.usbCandidate([unauthorized]) {
            #expect(d.state == .unauthorized)
        } else { Issue.record("expected needsAuthorization") }

        if case .disconnectedOrOffline = DeviceListParser.usbCandidate([offline]) {} else {
            Issue.record("expected disconnectedOrOffline")
        }

        if case .none = DeviceListParser.usbCandidate([emulator, network]) {} else {
            Issue.record("expected none for emulator/network only")
        }
    }

    @Test func networkSerialDetection() {
        #expect(DeviceListParser.isNetworkSerial("192.168.1.5:5555"))
        #expect(DeviceListParser.isNetworkSerial("usb:1-3") == false)
        #expect(DeviceListParser.isNetworkSerial("78935a57") == false)
        #expect(DeviceListParser.isNetworkSerial("localhost:5555"))
    }
}

/// Regression tests for command-specific exit-status handling: these run
/// the REAL AdbClient against a scripted "adb" executable whose exit codes
/// and stderr model what an actual device reports. The earlier dispatch
/// layer threw for every nonzero exit, so stat-on-missing-file aborted
/// callers (DeviceFileService.upload's existence check failed for every
/// new filename) and remoteSHA256's optional-tool fallback was unreachable.
/// Fakes cannot catch this: they model intended semantics, not dispatch.
@Suite struct AdbClientStatusInterpretationTests {
    /// Behavior keyed on the remote path's last component; unrecognized
    /// paths succeed like an existing file.
    ///
    /// adb passes a remote shell command as ONE argument, so the fixture
    /// parses the command line rather than loose argv words: the remote
    /// path is the trailing single-quoted word after "--".
    static let scriptedAdbBody = """
    #!/bin/sh
    # argv: -s SERIAL shell "stat -c '%s|%Y|%F' -- 'PATH'"
    #    | -s SERIAL shell "sha256sum -- 'PATH'"
    if [ "$1" = "-s" ]; then shift 2; fi
    cmdline="$2"
    path=$(printf '%s' "$cmdline" | sed -e "s/^.*-- '//" -e "s/'$//")
    last=$(printf '%s' "$path" | sed 's|.*/||')
    case "$last" in
      absent.txt)
        printf "stat: '%s': No such file or directory\\n" "$path" >&2
        exit 1 ;;
      denied.txt)
        printf "stat: '%s': Permission denied\\n" "$path" >&2
        exit 1 ;;
      notool.txt)
        printf "/system/bin/sh: sha256sum: not found\\n" >&2
        exit 127 ;;
      ioerror.txt)
        printf "sha256sum: %s: Input/output error\\n" "$path" >&2
        exit 1 ;;
    esac
    case "$cmdline" in
      sha256sum*)
        printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  %s\\n' "$path"
        ;;
      *)
        printf '123|1700000000|regular file\\n'
        ;;
    esac
    exit 0
    """

    func scriptedAdb() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boox-status-adb-\(UUID().uuidString).sh")
        try Self.scriptedAdbBody.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func statOnAbsentRemoteFileReturnsNilNotError() async throws {
        let client = try AdbClient(executableURL: try scriptedAdb())
        let absent = try RemotePath("/sdcard/note/absent.txt")
        let record = try await client.stat(remote: absent, serial: "78935a57")
        #expect(record == nil)
    }

    @Test func statPermissionFailureStillSurfaces() async throws {
        let client = try AdbClient(executableURL: try scriptedAdb())
        let locked = try RemotePath("/sdcard/note/denied.txt")
        await #expect(throws: AdbClientError.self) {
            _ = try await client.stat(remote: locked, serial: "78935a57")
        }
    }

    @Test func statParsesPresentFile() async throws {
        let client = try AdbClient(executableURL: try scriptedAdb())
        let there = try RemotePath("/sdcard/note/there.txt")
        let record = try await client.stat(remote: there, serial: "78935a57")
        #expect(record?.sizeBytes == 123 && record?.isRegularFile == true)
    }

    @Test func missingRemoteHashToolFallsBackToNil() async throws {
        let client = try AdbClient(executableURL: try scriptedAdb())
        let target = try RemotePath("/sdcard/note/notool.txt")
        let hash = try await client.remoteSHA256(remote: target, serial: "78935a57")
        #expect(hash == nil)
    }

    @Test func hardHashFailureSurfacesInsteadOfNil() async throws {
        let client = try AdbClient(executableURL: try scriptedAdb())
        let target = try RemotePath("/sdcard/note/ioerror.txt")
        await #expect(throws: AdbClientError.self) {
            _ = try await client.remoteSHA256(remote: target, serial: "78935a57")
        }
    }

    @Test func hashOfPresentFileParses() async throws {
        let client = try AdbClient(executableURL: try scriptedAdb())
        let target = try RemotePath("/sdcard/note/there.txt")
        let hash = try await client.remoteSHA256(remote: target, serial: "78935a57")
        #expect(hash == String(repeating: "deadbeef", count: 8))
    }
}
