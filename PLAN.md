# Boox Bridge — master documentation index

Boox Bridge imports auto-exported Boox notebook PDFs over USB, keeps a
durable offline library with searchable transcriptions, and transcribes
pages with user-configured vision models. PDF-first scope; deliberately
non-destructive: copying is one-way (device → Mac), nothing on the device
is ever deleted, renamed, or moved by a sync.

**Read this file, then [PROGRESS.md](PROGRESS.md), and you are up to speed.**

## Topic guides

| Guide | What it covers |
|---|---|
| [plans/boox-workflow.md](plans/boox-workflow.md) | The user workflow: first run, enrolling an export folder, importing, reading, transcribing, exporting. |
| [plans/usb-and-sync.md](plans/usb-and-sync.md) | ADB process management, device discovery/authorization, path safety, staging/hash verification, revisions, the bounded file browser, and the remote-mutation policy. |
| [plans/ocr-providers.md](plans/ocr-providers.md) | Provider adapters and wire contracts, endpoint/credential security, the durable OCR queue, retries, and the synthetic capability probe. |
| [plans/architecture.md](plans/architecture.md) | Target split (platform-neutral core vs macOS app), layering, and the seams every test drives. |
| [plans/build-system.md](plans/build-system.md) | SwiftPM-only builds, bundling/signing (hardened runtime, non-sandbox), Make targets, platform gates. |
| [plans/design-system.md](plans/design-system.md) | Type, metrics, and native macOS interface conventions used by the app. |
| [plans/renaming.md](plans/renaming.md) | How the template rename works and the names that must stay in agreement. |

## Development gates

- **Linux (this repo's CI-side host):** `make test-core` (plain `swift
  test`) — 57 platform-neutral tests over parsing/quoting/path policy,
  process lifecycle, catalog durability, import integration, transfers,
  provider wire contracts, endpoint security, and the OCR queue.
- **macOS:** `make check`, `make test` (core + app test target), bundle
  build, then `make run` for live visual/device verification.
- **Physical device:** the manual checks in plans/usb-and-sync.md §9. The
  implementation is NOT considered hardware-verified until those results
  exist in PROGRESS.md.

## Standing contracts

- `AGENTS.md` / `CLAUDE.md`: keep this index current, log progress, never
  merge a PR to main yourself.
- `PROBLEMS.md`: hard-won gotchas specific to this app.
- `SWIFTUI-RULES.md`: SwiftUI failure modes learned the hard way.
