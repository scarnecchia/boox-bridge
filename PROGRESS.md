# PROGRESS.md

Review and delivery status for BooxBridge. Last updated: 2026-11-14.

## Current state

- Branch `boox-bridge-implementation` at `88c0c27`; PR #1 is open. Merging stays with the operator (AGENTS.md).
- PR #1 review: four two-reviewer code-review fix rounds complete. Round 1 landed before `19ee661`; rounds 2–4 are the `19ee661..88c0c27` range (fix branches `fix/pr1-adb-sync`, `fix/pr1-app-ui`, `fix/pr1-ocr-core`, `fix/r2-app-lifecycle`, `fix/r2-transport`, plus the final seam fixes at `77df9ec`..`88c0c27`).
- Tests: 111 tests in 17 suites pass on Linux (`swift test`, core only), verified 2026-11-14.
- macOS gate outstanding: the app targets have never been compiled on this machine. Two compile defects introduced by the round-3 seams were fixed statically at `88c0c27`. `make check`, `make test`, and `make run` on a Mac remain pending (AGENTS.md "Verify your work").

## Contract and behavior changes from rounds 2–4 (`19ee661..88c0c27`)

- OcrRunner no longer holds a credential store: `drain(profileResolver:)` receives a `DrainCredential` (endpoint + key captured coherently per drain in `AppEnvironment.spawnDrain`); rotation takes effect on the next drain. Jobs execute their STORED model and prompt (the job row); unsupported prompt versions and empty model IDs fail closed without network.
- Test Connection probes the draft origin with an ephemeral key only and never mutates stored credentials. All credential writes flow through CredentialFlow save plans (rotate at save time, fail-closed on keychain errors).
- `CatalogStore.enqueueJob` resets terminal jobs in place: returns the job id for new-or-reset, nil only for an active dedupe hit, no throw for terminal duplicates. The new `terminalJobs(limit:)` query powers Activity history (update-time ordered, folder-independent).
- `EndpointPolicy.normalizedOrigin` (scheme + host + effective port) is the single origin authority; redirects revalidate the full policy.
- adb listings reject `stdoutTruncated` before parsing; AdbClient distinguishes absent-file / missing-tool nonzero exits from errors.
- HTTPTransport: session-level delegate; cancellation bridges to the URLSessionTask with an immediate CancellationError; overlapping sends on one instance are safe.
- OCRDrainOwnership: `requestStart(live)` arms a restart without cancelling; explicit Cancel disarms and cancels; stale completions are ignored.
- PreviewSizing is a pure type that fits the preview to the viewport at zoom 1.0.

## Known open (operator decision, intentionally unfixed)

1. `AppEnvironment.hasStoredKey` collapses Keychain read errors to false, so Save on a changed origin can keep the old secret.
2. `saveProfiles` suppresses providers.json write failures, so a failed rotation write can pair the new key with the stale old endpoint after restart.

Both are documented in the PR #1 review record and were intentionally left open.

## Context files

- AGENTS.md re-verified against the code on 2026-11-14: all documented invariants intact (app name in its four coupled places, macOS 26.1 floor in its three places, core isolation, ProcessRunner exclusivity, Theme ownership of constants, `// pattern:` headers). No changes required.
