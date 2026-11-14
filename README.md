# Boox Bridge

Import auto-exported Boox notebook PDFs over USB, read them offline, and
transcribe pages with your own vision-model provider.

Boox Bridge is deliberately **non-destructive**: copying is one-way
(device → Mac). Nothing on the Boox is ever deleted, renamed, or moved by
a sync. First release is PDF-first — `.note` files are surfaced as
unsupported, not faked.

## What it does

- **USB import** — discovers a USB-authorized Boox via your own adb,
  imports from export folders you enroll, verifies every file with
  metadata + SHA-256 checks before committing, and creates revisions when
  you re-export a notebook (previous originals are always preserved).
- **Offline library** — content-addressed originals, page previews,
  full-text search over titles and transcripts, TXT/Markdown export with
  your edits preserved.
- **Transcription** — explicit, per-page, durable queue to OpenAI,
  Anthropic, DeepInfra, Z.ai, or any OpenAI-compatible endpoint. API keys
  stay in the Keychain; a synthetic-image Test Connection verifies the
  exact profile+model before you spend anything.
- **Bounded file transfers** — browse the device within your chosen
  folder; download, create folders, and upload as explicit actions with
  race-safe publishing.

## Prerequisites

1. macOS 26.1+ (Tahoe).
2. Android platform-tools (adb) installed by you —
   <https://developer.android.com/tools/releases/platform-tools>. Boox
   Bridge never bundles or downloads it.
3. USB debugging enabled on the Boox (Settings → About → tap build →
   Developer options), and the debugging prompt accepted.
4. Boox PDF auto-export enabled for your notebooks. `/sdcard/note` is the
   usual output folder on recent firmware; enroll the actual folder in
   the app.
5. A provider API key (OpenAI / Anthropic / DeepInfra / Z.ai). API keys
   are not ChatGPT subscription credentials; vision requests bill against
   the provider account. Pages leave your Mac as images when you
   transcribe.

## Building (no Xcode project needed)

```sh
make test-core   # platform-neutral tests (macOS or Linux)
make check       # compile-only
make test        # tests incl. macOS app target (Mac only)
make run         # build + launch the .app
```

Signing is ad-hoc by default with the hardened runtime enabled;
non-App-Store and non-sandboxed by design (the app must spawn adb).
`dev.booxbridge.app` is a development bundle id — replace it before
distributing.

## Developer notes

Documentation index: [PLAN.md](PLAN.md). Status log: [PROGRESS.md](PROGRESS.md).
Architecture, USB/sync safety, and provider details live under [plans/](plans/).

Boox Bridge was developed test-first on Linux (57 core tests) with macOS
UI/device verification performed on a Mac; see PROGRESS.md for exactly
which checks have run.
