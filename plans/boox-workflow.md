# Boox workflow — first run to export

## 1. Prerequisites (documented, not automated)

1. **adb** — install Android platform-tools yourself:
   <https://developer.android.com/tools/releases/platform-tools>. Boox
   Bridge never bundles or downloads adb. In the app: Settings → Device
   Import → Browse… to the executable, then Verify (runs `adb version`).
2. **USB debugging on the Boox** — Settings → About → tap the build number
   until Developer Options appear, enable USB debugging, connect, and
   accept the debugging prompt on the device.
3. **PDF auto-export on the Boox** — in the Notes app, enable PDF export
   for your notebooks. Boox Bridge reads whatever folder the device writes;
   it does not assume a fixed firmware path. `/sdcard/note` is the usual
   location on recent firmware and is offered as a suggestion only.

Manual local-file import (open a PDF/PNG/JPEG directly) exists as a
fallback when USB is unavailable.

## 2. First run

1. Configure adb (above). The footer shows device states with actionable
   explanations: no device / unauthorized / offline / multiple devices.
2. Enroll an export folder: Settings → Device Import → type or browse the
   device folder (default suggestion `/sdcard/note`) → Enroll Current
   Device. Enrollment records the device serial + folder.
3. Sync Now (⌘S) or just connect while the app runs — auto-import covers
   enrolled folders only, only while the app is open, and only for the
   unambiguous USB device (emulators and network serials never qualify).
4. Each file is pulled through staging with pre/post metadata and SHA-256
   checks; files still being written by the device's export are deferred
   and retried on the next sync, never committed half-written.

## 3. Reading offline

The library is fully offline: originals are content-addressed blobs under
Application Support, page previews render from the local copy, and search
(FTS5) runs over titles, folders, and effective transcript text. No USB or
network connection is needed to read, search, or edit.

Documents are identified by device serial + enrolled folder + relative
path. Content hashes identify revisions: re-exported content becomes a new
revision while the previous original and its transcript edits are
preserved. A remote rename therefore appears as a new document — this is
deliberate; hashes do not establish identity.

`.note` files are surfaced explicitly as unsupported — never treated as
PDFs.

## 4. Transcribing

1. Settings → Providers: pick a preset (OpenAI, Anthropic, DeepInfra,
   Z.ai) or a custom OpenAI-compatible endpoint; set the model id (use
   Suggested for known vision models; DeepSeek text models are not
   suggested because image support is per-model — verify with Test
   Connection); paste the API key (stored only in the Keychain).
2. Test Connection sends one tiny synthetic image — never a page from your
   notes — and records verified/rejected for that exact profile+model.
3. In a document, Transcribe opens a disclosure naming provider, model,
   page count, and that requests may bill and pages leave this Mac.
   Confirm to queue.
4. The queue is durable and per page: success persists across restarts;
   interrupted jobs surface as resumable failures (never silently
   restarted, since a paid request may already have been sent). Re-running
   OCR never overwrites your edits — raw model output and your effective
   text are stored separately.
5. Activity shows per-page state, errors, retry/cancel. Cancelling stops
   new pages; a request already in flight may still have been billed.

## 5. Exporting and organizing

- Export as TXT or Markdown from the document toolbar (native save panel);
  page order and your edits are preserved.
- Reveal Original in Finder opens the content-addressed blob.
- Deleting from the library is local-only with confirmation: originals and
  revisions stay on the Mac, and nothing is ever sent to the device.

## 6. API keys vs subscriptions

Provider profiles use provider API keys, not ChatGPT/subscription
credentials. Vision requests bill against the provider account per their
pricing; pages are sent as images to the configured endpoint only.
