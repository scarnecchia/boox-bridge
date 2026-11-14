// pattern: Mixed (unavoidable)
// Reason: SwiftUI app entry must construct the environment (I/O) and declare
// the scene graph in one type; the logic itself lives in AppEnvironment.

import BooxBridgeCore
import SwiftUI

@main
struct BooxBridgeApp: App {
    @State private var environment: AppEnvironment?
    @State private var bootError: String?
    let scenario: ScenarioKind?

    init() {
        // --ui-test-scenario <name> is the ONLY way fixtures activate.
        var scenario: ScenarioKind?
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--ui-test-scenario"), index + 1 < arguments.count {
            scenario = ScenarioKind(rawValue: arguments[index + 1])
        }
        self.scenario = scenario
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let environment {
                    RootView()
                        .environment(environment)
                } else if let bootError {
                    ContentUnavailableView("Boox Bridge could not start",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(bootError))
                } else {
                    ProgressView("Opening library…")
                }
            }
            .task { await bootIfNeeded() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Sync Now") { Task { await environment?.syncNow() } }
                    .keyboardShortcut("s", modifiers: [.command])
                    .disabled(environment == nil)
                Button("Cancel OCR") { environment?.cancelOCRDrain() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .disabled(environment == nil)
            }
            CommandMenu("Go") {
                Button("Library") { NotificationCenter.default.post(name: .booxNavigate, object: "library") }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Device Files") { NotificationCenter.default.post(name: .booxNavigate, object: "deviceFiles") }
                    .keyboardShortcut("2", modifiers: [.command])
                Button("Activity") { NotificationCenter.default.post(name: .booxNavigate, object: "activity") }
                    .keyboardShortcut("3", modifiers: [.command])
            }
        }

        Settings {
            if environment != nil {
                SettingsView()
            } else {
                Text("Settings unavailable until the app finishes starting.")
            }
        }
    }

    @MainActor
    private func bootIfNeeded() async {
        guard environment == nil, bootError == nil else { return }
        do {
            if scenario != nil {
                // Scenario mode: isolated temporary library, deterministic
                // services, no USB/network/ADB.
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("boox-scenario-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                environment = try AppEnvironment(supportDirectory: temp, scenario: scenario)
            } else {
                let support = try AppPaths.applicationSupport()
                let env = try AppEnvironment(supportDirectory: support, scenario: nil)
                environment = env
                env.startDeviceMonitoring()
            }
        } catch {
            bootError = String(describing: error)
        }
    }
}

extension Notification.Name {
    static let booxNavigate = Notification.Name("boox-navigate")
}
