# Progress

Running log. Append an entry per meaningful change: what you did, what you
learned, what surprised you (`SWIFTUI-RULES.md` §10.1). Newest at the top.

> Once you've renamed the template, the entry below is history — leave it as
> the record of where the scaffold came from, and log your own work above it.

---

## 2026-11-13 — Adversarial review round 1: findings fixed with regression coverage

A general-purpose reviewer audited the full tree (concurrency, shell
injection/path isolation, credential leakage, durability, wire contracts,
static macOS-UI risk). Headline findings and dispositions — all fixed,
each critical/high covered by a new regression test (60 tests now pass on
Linux, ~1.5s):

1. **CRITICAL (verified by reviewer, now regression-tested end-to-end):**
   the remote listing script read only `$1`, but `find -exec sh -c … {} +`
   passes each batch as positional parameters — one record per batch was
   emitted and the rest silently dropped. Fixed with `for f do … done`;
   `listingScriptEndToEndAgainstRealShell` now runs the actual script via
   /bin/sh over a 16-file hostile-name tree and requires every record.
2. **CRITICAL:** launch recovery stored its Task in `pollingTask`, so
   device polling could never start. Separate `recoveryTask` property.
3. **HIGH:** Cancel OCR did not stop the drain loop — the loop now checks
   `Task.isCancelled` before scheduling each page (in-flight request may
   still complete/bill, as the UI discloses).
4. **HIGH:** unchanged content with changed mtime never refreshed stored
   remote metadata → permanent re-pull loop. The dupe path now updates
   `remote_mtime`/`remote_size`; test proves the planner then classifies
   the file unchanged.
5. **HIGH:** re-importing a locally deleted document hit the UNIQUE
   constraint. Lookup now ignores `deleted_at` and re-import RESTORES
   visibility (same content → unchanged; new content → new revision on
   the restored document) — both covered by tests.
6. **MEDIUM:** same-origin redirects re-attached a nil Authorization
   header (stripping auth). The transport now carries our original
   credential headers onto allowed redirects only.
7. **MEDIUM:** editing a profile's base URL silently reused the stored
   key for a new host. Settings now clears the stored key when the
   endpoint host/scheme changes and tells the user to re-enter it.

The reviewer's remaining findings were low-severity/style items not
itemized in the retained report; credential handling was assessed sound
(secrets never reach errors, logs, or the catalog). macOS/device checks
remain pending exactly as listed above.

## 2026-11-13 — Boox Bridge implementation (automatable scope complete on Linux)

Implemented the approved plan end-to-end for everything Linux-verifiable;
commits 4058d65 → current. Swift 6.4.2 became available mid-session and
cleared the earlier toolchain blocker.

**Core (all cross-platform, 57 tests green on Linux, ~1.6s):**
- Rename/template teardown: fixture-tested portable rename (GNU/BSD sed),
  display name `Boox Bridge`, dev bundle id `dev.booxbridge.app`,
  non-sandbox entitlements with documented rationale.
- Package split `BooxBridgeCore`/`CBooxSQLite` (+swift-crypto 3.x) with
  macOS-only targets manifest-gated on `canImport(AppKit)`.
- ADB layer: validated executable, explicit argv, concurrent capped pipe
  drain, POSIX `kill(2)` watchdog (SIGINT→SIGKILL). TWO host bugs found by
  tests: corelibs `Process.interrupt/terminate` deliver no signal here
  (a hung child lived out its full `sleep`), and results raced stream
  EOF. Both fixed and covered.
- NUL-delimited listing with hostile-filename fixtures (unicode, quotes,
  newlines, tabs, leading hyphens); traversal/containment enforced at
  every layer; two quoting regimes kept separate.
- SQLite catalog: multi-statement DDL tail-walking (a real bug — prepare
  stops at the first statement and the tail pointer must be copied while
  the C buffer lives), migrations, FTS5 (regular, not contentless —
  contentless forbids DELETE), revisions, library-only deletion,
  interrupted-job recovery.
- Import orchestration: pre/post-stat + hash deferral, invalid-file
  protection of current revisions, no-deletion-inference, single-flight
  per root.
- Device files: bounded browse, staged downloads with consent, upload via
  app-owned temp + `mv -n` publish with race abort; remote overwrite
  disabled and documented; rm guarded to app-owned temp names; import path
  proven mutation-free by test.
- Providers: four presets + custom adapter, exact wire contracts,
  HTTPS/loopback policy enforced at runner AND transport, redirect
  cross-origin blocking, synthetic-image capability probe, durable queue
  (dedupe, restart-interruption, stale-revision double-check, edit
  preservation), bounded Retry-After-aware backoff, credential redaction
  verified against the catalog bytes.

**macOS app (written; NOT compiled or run — no macOS host):** Navigation
split UI (Library/Device Files/Activity), document detail with PDFKit
preview + adjacent transcript editor + consent-gated OCR, settings for
providers and device import, `--ui-test-scenario` fixture mode, Keychain
and PDFKit adapters, app test target (bundle smoke with hardened-runtime
assertions, AX prerequisite check that reports blocked-not-passed,
rendering fixtures, Keychain isolation).

**Unrun checks (evidence pending, not passes):** every macOS-only test;
`make check/test/run` on a Mac; build.sh hardening verification via
codesign; all physical-device items in plans/usb-and-sync.md §9 (real
import/reconnect/offline/OCR/transfers on the Note Air 5C); visual and
VoiceOver review. The `swiftui-pro` and `macos-design` skills remain
unregistered — UI followed SWIFTUI-RULES.md, typography-designer, and
HIG; typography-designer WAS loaded before UI work.

**Docs:** PLAN.md rewritten as index; plans/boox-workflow.md,
usb-and-sync.md, ocr-providers.md added; architecture/build/design
guides updated; README rewritten.

## 2026-11-13 — Boox Bridge implementation prerequisite check

Started the approved PDF-first Boox Bridge plan from the supplied plan text.
Implementation is blocked before the rename/target split: `swift --version`
returned `swift: command not found`. Swift was not found in the checked
conventional `/opt` and `/usr/local` locations; the usual home swiftly
locations are absent. A broad home search hit its walk limit, so this is
not proof that no compiler exists anywhere on disk. No installation or
download was attempted. A working Linux Swift toolchain is required before
implementing the plan's test-gated core.

Verified SQLite 3.54.1 via pkg-config and CLI, confirmed
`/usr/include/sqlite3.h` is readable, and successfully created an in-memory
FTS5 table. Read the package, rename script, bundle script, Makefile,
project instructions and relevant SwiftUI rules. Confirmed the rename
script needs a portable replacement for BSD-only in-place sed and both
bundle signing paths need hardened-runtime options. No implementation
source/build changes, device operations or paid API calls occurred.

Loaded coding-effectively, howto-functional-vs-imperative,
defense-in-depth and writing-good-tests. No readable matching swiftui-pro
or macos-design skill copies were found in the searched Polytoken/Claude
skill locations; these checks have not passed. UI implementation and its
remaining design guidance/setup have not started. macOS builds, UI,
Keychain, physical USB and provider acceptance remain unrun.

## 2026-06-28 — Metabolized learnings from the first app on this template

Folded `LEARNINGS.md` (general lessons from building the first app — an
outdoor-weather feature — on this scaffold) into the permanent docs, then
deleted the copy. Where each landed:

- `SWIFTUI-RULES.md` **§5.6** — `foregroundStyle` resolves innermost-wins (a
  tinted container can host a differently-colored inline child; the corollary
  bites the "explicit `.foregroundStyle(.primary)`" habit).
- `SWIFTUI-RULES.md` **§11 Swift Charts** (new) — overlaid lines need distinct
  `series:` or they merge into one path; the x-domain is the union of all
  plotted data, so clip overlays to the primary series' window.
- `SWIFTUI-RULES.md` **§12 Concurrency** (new) — a `@MainActor` type adopting a
  delegate protocol needs an isolated conformance (`@MainActor CLLocationManagerDelegate`).
- `plans/build-system.md` — new "Permissions & capabilities" section: usage
  prompts work in this ad-hoc-signed, no-Xcode bundle given the right
  `NS…UsageDescription` keys; the sandbox decides whether a `com.apple.security.*`
  entitlement is also needed; always design the denied path.

Appended §11/§12 rather than renumbering so the existing §9/§10 cross-references
in `PLAN.md` / `PROGRESS.md` stay valid.

## 2026-06-28 — Template scaffold (the "BooxBridge" baseline)

Built the template this repo ships as:

- **Build system** lifted from the Casette app's SwiftPM-only setup and
  generalized: `Package.swift` (one exe + one test target, Swift 6 mode, no
  deps), `build.sh` (swift build → `.app` → codesign, ad-hoc fallback),
  `Makefile` (build/check/test/run/install + sign→notarize→staple→zip `dist`
  pipeline), `Resources/Info.plist`, sandboxed `BooxBridge.entitlements`,
  `scripts/make-icon.swift` (pure-CoreGraphics doc-and-table glyph).
- **App**: `NavigationSplitView` with a `SidebarSection` enum driving a lorem
  reading column (`ReadingView`, measure-capped) and a native sortable `Table`
  (`DataTableView`) with a reusable `StatusBadge` and a footer count. State in
  one `@Observable @MainActor AppModel`; type/metrics centralized in `Theme`.
- **`scripts/rename.sh`** — the meta feature: `cp -R` then one command renames
  target, `.app`, bundle id, dirs, and file contents.
- **Tests**: swift-testing suite covering model load + status sort ordering.
- **Docs**: this file, `PLAN.md` (index, written for the fresh-copy workflow),
  `PROBLEMS.md`, and `plans/{architecture,build-system,design-system,renaming}.md`.

Gates run: `make check` ✓, `make test` ✓ (3 tests), `make build` ✓ (icon +
signed `.app`), live launch ✓ — both destinations render correctly, app stays
alive across a sidebar switch (no constraint crash).

Design work was driven through the macos-design, typography-designer, and
swiftui-pro skills per `CLAUDE.md`, before and after writing the views.
