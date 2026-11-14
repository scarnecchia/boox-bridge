# USB and sync — adb, safety, revisions, transfers

## 1. Process management

`FoundationProcessRunner` (BooxBridgeCore/Adb/ProcessRunner.swift) is the
only process spawner:

- Explicit argv, never `/bin/sh -c`; environment inherited.
- Both output pipes drained concurrently under per-stream byte caps.
- Results are finalized only after both streams reach EOF (a race here
  silently truncates output — see PROGRESS.md 2026-11-13).
- Timeout via a detached kill-watchdog; signals are delivered with
  `kill(2)` directly because `Process.interrupt()/terminate()` are
  unreliable on some hosts: SIGINT first, SIGKILL after a grace period.
  SIGKILL cannot be ignored, so a hung adb can never outlive its deadline.
- The user's global adb server is never started or stopped by us.

`AdbClient` is an actor wrapping a validated executable URL (must exist,
be a regular file, and be executable). Every operation goes through
`AdbCommandBuilder` argv construction; conventional install paths are
offered as suggestions only, never executed.

## 2. Discovery and authorization

`adb devices -l` is parsed by a pure parser into states: device /
unauthorized / offline / recovering / sideload. Emulator serials
(`emulator-*`) and network serials (`host:port`) never qualify for USB
auto-import. One ready USB device → automatic; several → the UI demands an
explicit choice; unauthorized → instructions for enabling USB debugging.

Every device operation is scoped `-s serial`. Polling runs at a modest
interval only while the app runs (injectable clock in tests). Auto-import
fires only for enrolled serial+roots and coalesces concurrent runs into
one task per root.

## 3. Remote path safety

`RemotePath` validates absolute POSIX paths: NUL rejected (the only byte a
path can never contain), `.`/`..` rejected, normalization never repairs
traversal, and containment (`isWithin(root)`) is enforced at every layer.
Newlines and tabs are legal filename bytes and survive end-to-end because
listings are NUL-delimited and quoting escapes everything.

Two quoting regimes, never mixed:

- `adb shell <script>` joins argv with spaces into a real shell string —
  every remote path inside a script is POSIX single-quoted
  (`ShellQuoting`); filenames produced by the script stay inside `"$1"`.
- `adb pull`/`push` are parsed by adb itself (sync protocol, no shell) —
  paths pass as plain argv elements.

The listing script is:

```
find 'ROOT' -type f -exec sh -c \
  'printf "%s\t" "$(stat -c '\''%s|%Y|%F'\'' -- "$1")"; printf "%s\0" "$1"' sh {} +
```

Records are `size|mtime|kind<TAB>path<NUL>`. Malformed records, paths
outside the root, or a truncated listing (missing final NUL) fail the
entire listing — a partial listing is never treated as authoritative,
which would fabricate remote deletions.

## 4. Import pipeline (device → Mac, one-way)

For each enrolled root: list → `ImportPlanner` (pure diff vs catalog
snapshots; unchanged size+mtime is a no-op) → for each pull: pre-stat →
pull into unique staging → post-stat (changed metadata = unstable, defer)
→ local SHA-256 vs device `sha256sum` when available (mismatch = defer) →
format validation (magic bytes + limits; PDFKit on macOS) → commit blob
(atomic move, content-addressed) → catalog transaction. Invalid files keep
the previous revision current. Staging is scrubbed at launch; committed
content lives in `blobs/`.

## 5. Revisions and identity

Document identity = serial + root + relative path. Revision identity =
content hash. Unchanged re-import is a no-op; changed content adds a
revision (previous originals and transcript edits preserved). Local
deletion is catalog-only with confirmation; nothing is ever propagated to
the device — including after successful scans.

## 6. Bounded file browser and explicit transfers

`DeviceFileService` browses within the user-chosen shared-storage root
(directories first). Writes happen only on explicit action:

- **Download** — pull into a unique local staging name, then move into the
  user-chosen folder; existing files are replaced only with explicit
  consent per sync.
- **Upload** — push to an app-owned temporary sibling
  (`.booxbridge-upload-<uuid>-<name>`), verify the staged size, publish
  with `mv -n` (no-clobber), then verify the final size. If the destination
  appeared concurrently, nothing is overwritten: the temp is cleaned up
  and a publish-race error surfaces. Remote overwrite is DISABLED in this
  release (a remove+rename window cannot be made safe with tested adb
  capabilities); the error tells the user to move/remove the file on the
  device. Cancel/disconnect preserves device state; cleanup targets only
  app-owned temp names.
- **New folder** — `mkdir -p` on a validated name within the root.

## 7. Remote mutation policy (tested)

`AdbCommand` exposes exactly two mutations: `moveRemoteNoClobber` (upload
publish) and `removeRemote` (app-owned temp cleanup). `AdbClient`
*refuses* `removeRemote` for any name lacking the app temp prefix, and the
import path issues zero remote mutations — both asserted by
`remoteMutationPolicy` tests. There is no remote delete/rename/mirror
command anywhere in the codebase.

## 8. What is intentionally absent

`.note` parsing/rendering, private native-database extraction, MTP, WebDAV,
cloud sync, embeddings/chat, red-ink task extraction, automatic cloud OCR,
background launch agents, and two-way mirroring. See PLAN.md scope notes.

## 9. Manual hardware checklist (run on macOS with the Note Air 5C)

Record dated results in PROGRESS.md; absent results leave hardware
acceptance pending.

1. `make run` with the device connected and authorized — expect
   `connected: Note Air 5C (78935a57)` and a successful Sync Now of
   `/sdcard/note` (or your actual export folder).
2. Edit a notebook on the device, re-export, sync — expect a new revision
   with the previous one intact.
3. Disconnect, relaunch, open/search/transcribe-edit offline.
4. One real vision OCR against a known handwritten sample; record
   provider, model id, and quality notes (not exact-text expectations).
5. In Device Files: download a file, create a folder, upload a file,
   attempt an upload over an existing name (expect the disabled-overwrite
   explanation), pull the cable mid-upload (expect originals preserved and
   a clean error).
6. VoiceOver pass over Library / document detail / Settings.
