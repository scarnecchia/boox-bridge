// adbProcessLifecycle: exercises the REAL FoundationProcessRunner with a
// fixture executable — actual argv (no shell), stream capture, caps,
// timeouts, nonzero exits, and cancellation cleanup.
import Foundation
import Testing
@testable import BooxBridgeCore

@Suite(.serialized) struct ProcessLifecycleTests {
    /// Write a fixture "adb" script and return its URL. Modes:
    ///  - echo-args: prints each argument on its own line, exit 0
    ///  - fail: prints to stderr, exits 3
    ///  - hang: sleeps long enough to outlive the timeout (killable; bounded
    ///    at 8s so a failed kill cannot wedge the host)
    ///  - flood: writes >cap bytes
    func fixtureScript(_ mode: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boox-fixture-\(mode)-\(UUID().uuidString).sh")
        let body: String
        switch mode {
        case "echo-args":
            body = "#!/bin/sh\nfor a in \"$@\"; do printf '%s\\n' \"$a\"; done\nexit 0\n"
        case "fail":
            body = "#!/bin/sh\necho 'boom' >&2\nexit 3\n"
        case "hang":
            body = "#!/bin/sh\nexec sleep 8\n"
        case "flood":
            body = "#!/bin/sh\ni=0\nwhile [ $i -lt 4096 ]; do printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; i=$((i+1)); done\n"
        default:
            fatalError("unknown fixture mode")
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func runsRealProcessWithExplicitArgvAndCapturesStreams() async throws {
        let script = try fixtureScript("echo-args")
        let runner = FoundationProcessRunner()
        let hostile = "arg with 'quote' and $dollar; rm -rf /"
        let result = try await runner.run(ProcessRequest(
            executable: script,
            arguments: ["devices", "-l", "-s", "78935a57", "shell", hostile],
            timeout: 10
        ))
        #expect(result.succeeded)
        #expect(result.exitCode == 0)
        let lines = String(data: result.stdout, encoding: .utf8)!.split(separator: "\n").map(String.init)
        // Arguments pass through as separate argv elements — the hostile
        // string arrives as ONE line, un-mangled, because no shell joined them.
        #expect(lines == ["devices", "-l", "-s", "78935a57", "shell", hostile])
    }

    @Test func surfacesNonZeroExitAndStderr() async throws {
        let script = try fixtureScript("fail")
        let runner = FoundationProcessRunner()
        // The runner REPORTS exit codes; policy decisions live in AdbClient.
        let result = try await runner.run(ProcessRequest(executable: script, arguments: [], timeout: 10))
        #expect(!result.succeeded)
        #expect(result.exitCode == 3)
        #expect(String(data: result.stderr, encoding: .utf8)!.contains("boom"))
    }

    @Test func killsHangingProcessOnTimeout() async throws {
        let script = try fixtureScript("hang")
        let runner = FoundationProcessRunner()
        do {
            _ = try await runner.run(ProcessRequest(executable: script, arguments: [], timeout: 1))
            Issue.record("expected timeout failure")
        } catch let error as ProcessFailure {
            guard case .timedOut = error else {
                Issue.record("wrong failure kind: \(error)"); return
            }
        } catch {
            Issue.record("unexpected error kind: \(error)")
        }
    }

    @Test func capsOversizedOutput() async throws {
        let script = try fixtureScript("flood")
        let runner = FoundationProcessRunner()
        let result = try await runner.run(ProcessRequest(
            executable: script, arguments: [], timeout: 10, maxOutputBytes: 1024
        ))
        #expect(result.stdout.count <= 1024)
        #expect(result.stdoutTruncated)
    }

    @Test func reportsSpawnFailureForMissingExecutable() async {
        let runner = FoundationProcessRunner()
        do {
            _ = try await runner.run(ProcessRequest(
                executable: URL(fileURLWithPath: "/nonexistent/definitely-missing"),
                arguments: [], timeout: 5
            ))
            Issue.record("expected spawn failure")
        } catch let error as ProcessFailure {
            guard case .spawnFailed = error else { Issue.record("wrong failure: \(error)"); return }
        } catch {
            Issue.record("unexpected error kind: \(error)")
        }
    }

    @Test func adbClientValidatesExecutableBeforeUse() throws {
        #expect(throws: AdbClientError.invalidExecutable("/nonexistent/adb")) {
            _ = try AdbClient(executableURL: URL(fileURLWithPath: "/nonexistent/adb"))
        }
        #expect(throws: AdbClientError.self) {
            _ = try AdbClient(executableURL: URL(fileURLWithPath: "/tmp")) // directory, not a file
        }
    }
}
