# AGENTS.md

Working agreements for coding agents in this repository.

BooxBridge is a SwiftUI macOS app for importing Boox notebook PDFs over USB and transcribing them with vision models. The platform-neutral core in Sources/BooxBridgeCore also builds and tests on Linux. All targets use the Swift 6 language mode with strict concurrency.

Last reviewed: 2026-11-14.

## Documentation

- SWIFTUI-RULES.md — SwiftUI and Swift-concurrency rules, each with the failure mode that produced it. Apply it when you write or review a view.
- Build contracts live as comments in Package.swift, build.sh, and the Makefile. Run `make help` for the target list.
- Each source file starts with a `// pattern:` header that records its Functional Core or Imperative Shell classification. Keep that header when you create a file.

## Verify your work

- On macOS, run `make check` for the compile gate, then `make test` for the full suite.
- On Linux, run `swift test` (or `make test-core`). The suite covers the core only there. `make check` fails on Linux because its prerequisite check needs macOS.
- A passing test suite does not prove a working app (SWIFTUI-RULES.md §9). After a UI change, launch the app with `make run` and use the surface you changed before you call the work done.

## Invariants

- The app name appears in four coupled places: the SwiftPM target, APP_NAME in build.sh, CFBundleExecutable in Resources/Info.plist, and the entitlements path. scripts/rename.sh still targets the template name Starter and does nothing on this tree. Rename by hand and verify all four places.
- The macOS 26.1 floor lives in Package.swift, Resources/Info.plist, and MIN_MACOS in the Makefile. Change all three together.
- Sources/BooxBridgeCore must stay free of SwiftUI, AppKit, PDFKit, and Security imports. The manifest drops app targets on Linux, and the corePlatformIsolation test keeps the core clean on macOS too.
- ProcessRunner in Sources/BooxBridgeCore/Adb is the only process spawner. Reach adb through AdbClient, never with Process directly.
- New core logic goes in pure types marked `Functional Core`; side-effecting code lives in types marked `Imperative Shell`.
- Every font and layout constant comes from Sources/BooxBridge/Theme.swift. Add new metrics there, not inline in views.
- Write the test with the change, and add a regression test for every fix (SWIFTUI-RULES.md §9.4).
- Commit messages explain why the change exists, not what the diff shows (SWIFTUI-RULES.md §10.3).

## Delivery

- You may push branches and open pull requests. Never merge your own pull request into main. Merging stays with the operator.
