# Architecture

## Targets

| Target | Platforms | Contents |
|---|---|---|
| `CBooxSQLite` | macOS, Linux | system-library shim (`sqlite3.h` + link) |
| `BooxBridgeCore` | macOS, Linux | everything platform-neutral |
| `BooxBridge` | macOS only | SwiftUI app + platform adapters |
| `BooxBridgeCoreTests` | macOS, Linux | 57 core tests (`make test-core`) |
| `BooxBridgeAppTests` | macOS only | bundle smoke, AX scenario harness, PDFKit rendering, Keychain isolation |

The manifest includes the macOS targets only when `canImport(AppKit)`, so
Linux `swift test` never sees UI code. `corePlatformIsolation` scans core
sources to keep SwiftUI/PDFKit/AppKit/Security imports out of the core on
macOS too.

## Core layering (Functional Core / Imperative Shell)

Pure (no I/O; pattern comment `Functional Core`):

- `Adb/RemotePath` + `ShellQuoting` — path policy and quoting
- `Adb/AdbCommandBuilder` + `RemoteListingParser` — argv construction, NUL listing parsing
- `Adb/DeviceSnapshot` — `adb devices -l` parsing, USB candidate selection
- `Sync/ImportPlanner` — listing-vs-catalog diff
- `Documents/DocumentValidator` — magic-byte sniffing, limits
- `Persistence/CatalogModels`, `FTSQuery` — value types, FTS input escaping
- `OCR/ProviderModels`, `ProviderWire`, `EndpointPolicy`, `RetryPolicy` — profiles, wire codecs, policy
- `Export/TranscriptExporter` — TXT/Markdown generation

Side-effecting (pattern comment `Imperative Shell`):

- `Adb/ProcessRunner` — the only process spawner (kill(2) watchdog)
- `Adb/AdbClient` — actor over a validated adb executable
- `Sync/DeviceImportService` — staged, hash-verified import orchestration
- `Sync/DeviceFileService` — bounded browser + explicit transfers
- `Persistence/SQLiteDatabase`, `CatalogStore` — the only sqlite3 C-API code; migrations + FTS5
- `Storage/ManagedStorage` — content-addressed blobs, staging, previews
- `OCR/HTTPTransport` (URLSession + redirect guard), `OcrRunner` (durable queue)

Seams every test drives: `ProcessRunning`, `DeviceTransport`,
`HTTPTransporting`, `PageRendering`, `DocumentValidating`,
`CredentialStoring`, `ContentHashing`, `WallClock`.

## App layer (macOS)

- `AppEnvironment` (@MainActor @Observable) — owns service wiring, device
  polling, import triggering, library state, OCR enqueue/drain.
- `Adapters.swift` — Keychain store, PDFKit renderer/validator, app paths.
- Views: `RootView` (NavigationSplitView: Library / Device Files /
  Activity), `LibraryView`, `DocumentDetailView` (preview + adjacent
  transcript editor, export, OCR consent), `DeviceFilesView`,
  `ActivityView`, `SettingsView` (Providers, Device Import).
- `ScenarioServices` — deterministic fixtures behind the same seams,
  activated ONLY by `--ui-test-scenario`; normal startup never enables
  them.

## Storage layout

```
Application Support/Boox Bridge/
  catalog.sqlite          (+ -wal/-shm)
  providers.json          (non-secret profiles; keys are in the Keychain)
  library/blobs/ab/<sha256>   immutable originals
  library/staging/<uuid>/     in-flight pulls (scrubbed at launch)
  library/previews/           rendered page cache (rebuildable)
```

## Historical template docs

This guide replaced the template's orientation; the build, design, and
renaming guides remain (updated in place).
