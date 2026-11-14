// pattern: Functional Core
// Pure decision types for transcript editing: which persisted text is
// authoritative for a page, whether the detail editor's draft should reload
// when the persisted transcript changes, and how an enqueue batch reports
// itself. No I/O, no imports beyond Foundation — the views and AppEnvironment
// apply these decisions.

import Foundation

/// Which text wins for a page. Once a user has edited a page
/// (`lastEditedAt != nil`), the persisted effective text is authoritative —
/// INCLUDING intentionally emptied text. Only a never-edited page falls back
/// to its raw transcription. This mirrors the core TranscriptExporter rule so
/// the editor and the export agree on what a page says.
enum TranscriptAuthority {
    static func text(effectiveText: String, rawTranscription: String, lastEditedAt: Date?) -> String {
        if lastEditedAt != nil { return effectiveText }
        return effectiveText.isEmpty ? rawTranscription : effectiveText
    }
}

/// The persisted state the editor observes for the selected page, recomputed
/// on every body evaluation.
struct TranscriptDraftObservation: Equatable, Sendable {
    var revisionID: Int64?
    var pageID: Int64?
    var persistedText: String
}

/// What the editor should do with its draft after comparing its load state
/// against the latest observation.
enum TranscriptDraftDecision: Equatable, Sendable {
    /// Replace the draft with the given persisted text.
    case reload(String)
    /// Nothing changed; keep the draft untouched.
    case preserve
    /// The persisted text changed under a dirty draft: keep the user's edit,
    /// but surface the fresh persisted text so the UI can offer a reload.
    case preserveStale(String)
}

/// Clean-vs-dirty reload policy for the page editor. A draft reloads when the
/// revision or page identity changes, when it has never been primed, or when
/// the persisted transcript changed underneath a CLEAN draft (the OCR-writes-
/// within-the-same-revision case). A genuinely dirty draft is preserved so a
/// stale in-memory snapshot can never overwrite a fresh transcription on save.
struct TranscriptDraftPolicy: Equatable, Sendable {
    var loadedRevisionID: Int64?
    var loadedPageID: Int64?
    /// The persisted text the draft was last loaded from.
    var baselineText: String
    var draftText: String

    func decision(for observation: TranscriptDraftObservation) -> TranscriptDraftDecision {
        if observation.revisionID != loadedRevisionID || observation.pageID != loadedPageID {
            return .reload(observation.persistedText)
        }
        if observation.persistedText == baselineText {
            return .preserve
        }
        if draftText == baselineText {
            return .reload(observation.persistedText)
        }
        return .preserveStale(observation.persistedText)
    }
}

/// Accurate accounting for one enqueue batch. The store returns nil for a
/// deduplicated page (an active job with the same identity already exists) and
/// throws on real failures; neither may be silently folded into the queued
/// count.
struct EnqueueOutcome: Equatable, Sendable {
    var enqueued: Int
    var alreadyQueued: Int
    var failures: [String]
    var activityTitle: String
    var activityDetail: String

    static func report(
        enqueued: Int, alreadyQueued: Int, failures: [String],
        providerName: String, modelID: String
    ) -> EnqueueOutcome {
        if !failures.isEmpty {
            return EnqueueOutcome(
                enqueued: enqueued, alreadyQueued: alreadyQueued, failures: failures,
                activityTitle: "OCR queue incomplete",
                activityDetail: "\(enqueued) queued, \(alreadyQueued) already queued, "
                    + "\(failures.count) failed — \(failures.joined(separator: "; "))")
        }
        if enqueued == 0, alreadyQueued > 0 {
            return EnqueueOutcome(
                enqueued: enqueued, alreadyQueued: alreadyQueued, failures: failures,
                activityTitle: "OCR skipped",
                activityDetail: "All \(alreadyQueued) requested page(s) already have a queued or running job.")
        }
        var detail = "\(enqueued) page(s) → \(providerName) / \(modelID). Remote requests may bill per page."
        if alreadyQueued > 0 {
            detail += " \(alreadyQueued) additional page(s) were already queued."
        }
        return EnqueueOutcome(
            enqueued: enqueued, alreadyQueued: alreadyQueued, failures: failures,
            activityTitle: "OCR queued", activityDetail: detail)
    }
}
