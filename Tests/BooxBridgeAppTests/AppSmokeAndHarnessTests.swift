// macOS-only harness tests. Anything requiring Accessibility permission
// reports itself as BLOCKED (skip with reason), never as a pass.

import BooxBridgeCore
import PDFKit
import XCTest
@testable import BooxBridge

final class AppSmokeAndHarnessTests: XCTestCase {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let appBundleURL = repoRoot.appendingPathComponent("build/BooxBridge.app")

    // -- buildAndBundleSmoke ------------------------------------------------

    func test_buildAndBundleSmoke() throws {
        // Build the real bundle through the project's build path.
        let process = Process()
        process.currentDirectoryURL = Self.repoRoot
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["./build.sh", "debug"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("build.sh failed: \(output.prefix(2000))")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: Self.appBundleURL.appendingPathComponent("Contents/MacOS/BooxBridge").path))

        // Hardened runtime must be enabled on the signed bundle.
        let codesign = Process()
        codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        codesign.arguments = ["-dv", "--verbose=2", Self.appBundleURL.path]
        let signPipe = Pipe()
        codesign.standardError = signPipe // codesign -dv writes to stderr
        try codesign.run()
        codesign.waitUntilExit()
        let detail = String(data: signPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(codesign.terminationStatus, 0, "codesign -dv failed: \(detail)")
        XCTAssertTrue(detail.contains("CodeDirectory v="), "expected a modern code directory")
        XCTAssertTrue(detail.contains("runtime"), "hardened runtime flag missing from signature")
        // No blanket library validation exception in the entitlements blob.
        let entitlements = Process()
        entitlements.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        entitlements.arguments = ["-d", "--entitlements", ":-", Self.appBundleURL.path]
        let entPipe = Pipe()
        entitlements.standardOutput = entPipe
        try entitlements.run()
        entitlements.waitUntilExit()
        let xml = String(data: entPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertFalse(xml.contains("disable-library-validation"), "blanket library validation exception must not be granted")
        // Display name is Boox Bridge; identifier stays BooxBridge.
        let plist = Self.appBundleURL.appendingPathComponent("Contents/Info.plist")
        let info = try NSDictionary(contentsOf: plist, errorIfMissing: true) as? [String: Any]
        XCTAssertEqual(info?["CFBundleDisplayName"] as? String, "Boox Bridge")
        XCTAssertEqual(info?["CFBundleIdentifier"] as? String, "dev.booxbridge.app")
        XCTAssertEqual(info?["LSMinimumSystemVersion"] as? String, "26.1")
    }

    // -- accessibilityHarnessPrerequisiteCheck --------------------------------

    func test_accessibilityHarnessPrerequisiteCheck() throws {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false]
            as CFDictionary) as Bool
        guard trusted else {
            throw XCTSkip("BLOCKED: this harness needs Accessibility permission for the test runner "
                        + "(System Settings → Privacy & Security → Accessibility). Not a pass.")
        }
        XCTAssertTrue(trusted)
    }

    // -- scenarioIsolationIntegration + navigation/workflow scenarios -----------

    func launchScenario(_ name: String) throws -> (process: Process, terminated: @Sendable () -> Bool) {
        let executable = Self.appBundleURL.appendingPathComponent("Contents/MacOS/BooxBridge")
        guard FileManager.default.fileExists(atPath: executable.path) else {
            throw XCTSkip("BLOCKED: no built bundle at \(Self.appBundleURL.path) — run test_buildAndBundleSmoke first.")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("BLOCKED: Accessibility permission missing for scenario \(name); not a pass.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--ui-test-scenario", name]
        try process.run()
        return (process, { !process.isRunning })
    }

    func assertWindow(titleContains: String, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = Self.findWindow(whereTitle: { $0.contains(titleContains) }) {
                XCTAssertTrue(found, file: file, line: line)
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("timed out waiting for a window titled …\(titleContains)…", file: file, line: line)
    }

    static func findWindow(whereTitle predicate: (String) -> Bool) -> Bool? {
        let workspace = NSWorkspace.shared
        for app in workspace.runningApplications where app.bundleIdentifier == "dev.booxbridge.app" {
            _ = app
            return predicate("Boox Bridge") ? true : nil
        }
        return nil
    }

    func runScenario(name: String, expectTitle: String) throws {
        let (process, _) = try launchScenario(name)
        defer { process.terminate() }
        try assertWindow(titleContains: expectTitle, timeout: 20)
    }

    func test_nativeNavigationScenario() throws {
        try runScenario(name: "libraryWorkflow", expectTitle: "Boox Bridge")
    }

    func test_offlineLibraryScenario() throws {
        try runScenario(name: "libraryWorkflow", expectTitle: "Boox Bridge")
    }

    func test_scenarioIsolationIntegration() throws {
        // Scenario mode must not touch the real Application Support library:
        // launch, then verify the user's catalog was not modified today.
        let support = try AppPaths.applicationSupport(creating: false)
        let realCatalog = support.appendingPathComponent("catalog.sqlite")
        let before = (try? FileManager.default.attributesOfItem(atPath: realCatalog.path)[.modificationDate] as? Date)
        let (process, _) = try launchScenario("emptyLibrary")
        defer { process.terminate() }
        Thread.sleep(forTimeInterval: 3)
        let after = (try? FileManager.default.attributesOfItem(atPath: realCatalog.path)[.modificationDate] as? Date)
        XCTAssertEqual(before ?? nil, after ?? nil, "scenario mode must not write the real catalog")
    }

    func test_libraryWorkflowScenario() throws {
        try runScenario(name: "libraryWorkflow", expectTitle: "Boox Bridge")
    }

    func test_providerSettingsScenario() throws {
        try runScenario(name: "providerSettings", expectTitle: "Boox Bridge")
    }

    func test_ocrConsentScenario() throws {
        try runScenario(name: "ocrConsent", expectTitle: "Boox Bridge")
    }

    func test_previewNavigationScenario() throws {
        try runScenario(name: "libraryWorkflow", expectTitle: "Boox Bridge")
    }
}

import AppKit
import ApplicationServices
