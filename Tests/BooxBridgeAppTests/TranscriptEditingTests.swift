// pattern: Functional Core (decision-type regression tests)

import Foundation
import XCTest
@testable import BooxBridge

/// Regression tests for the transcript editor's pure decisions.
///
/// TranscriptAuthority: before this change the editor (like the old exporter)
/// fell back to raw OCR whenever effective text was empty — an intentional
/// emptying of a page was silently resurrected from raw OCR on the next load.
///
/// TranscriptDraftPolicy: before this change the draft only reloaded on
/// appear/revision/page change, so OCR writing within the same revision left
/// a stale draft in the editor, and saving it overwrote the fresh
/// transcription.
final class TranscriptEditingTests: XCTestCase {
    // MARK: - TranscriptAuthority (editor/export agreement)

    func test_editedEmptyBeatsRawOCR() {
        XCTAssertEqual(
            TranscriptAuthority.text(effectiveText: "", rawTranscription: "raw ocr", lastEditedAt: Date()),
            "",
            "an edit stamp with empty effective text must win over raw OCR")
    }

    func test_editedTextWins() {
        XCTAssertEqual(
            TranscriptAuthority.text(effectiveText: "user edit", rawTranscription: "raw ocr", lastEditedAt: Date()),
            "user edit")
    }

    func test_uneditedPagePrefersEffectiveText() {
        XCTAssertEqual(
            TranscriptAuthority.text(effectiveText: "ocr text", rawTranscription: "ocr text", lastEditedAt: nil),
            "ocr text")
    }

    func test_uneditedEmptyEffectiveFallsBackToRaw() {
        XCTAssertEqual(
            TranscriptAuthority.text(effectiveText: "", rawTranscription: "raw ocr", lastEditedAt: nil),
            "raw ocr")
    }

    func test_nilPageIsEmpty() {
        XCTAssertEqual(TranscriptAuthority.text(for: nil), "")
    }

    // MARK: - TranscriptDraftPolicy (reload decisions)

    private func observation(revision: Int64?, page: Int64?, text: String) -> TranscriptDraftObservation {
        TranscriptDraftObservation(revisionID: revision, pageID: page, persistedText: text)
    }

    func test_initialLoadReloads() {
        let policy = TranscriptDraftPolicy(
            loadedRevisionID: nil, loadedPageID: nil, baselineText: "", draftText: "")
        guard case .reload("ocr") = policy.decision(for: observation(revision: 7, page: 1, text: "ocr")) else {
            return XCTFail("unprimed editor must load")
        }
    }

    func test_sameRevisionTranscriptChangeReloadsCleanDraft() {
        // The OCR-completes-within-the-same-revision case: the draft was
        // loaded from "" and untouched; persisted now has fresh text.
        let policy = TranscriptDraftPolicy(
            loadedRevisionID: 7, loadedPageID: 1, baselineText: "", draftText: "")
        guard case .reload("fresh transcription") =
                policy.decision(for: observation(revision: 7, page: 1, text: "fresh transcription")) else {
            return XCTFail("clean draft must reload on a same-revision transcript change")
        }
    }

    func test_sameRevisionChangePreservesDirtyDraftAndSurfacesStale() {
        let policy = TranscriptDraftPolicy(
            loadedRevisionID: 7, loadedPageID: 1, baselineText: "", draftText: "user is typ")
        guard case .preserveStale("fresh transcription") =
                policy.decision(for: observation(revision: 7, page: 1, text: "fresh transcription")) else {
            return XCTFail("dirty draft must be preserved, with the fresh text surfaced")
        }
    }

    func test_revisionChangeReloadsEvenWhenDirty() {
        let policy = TranscriptDraftPolicy(
            loadedRevisionID: 7, loadedPageID: 1, baselineText: "", draftText: "user is typ")
        guard case .reload("new revision text") =
                policy.decision(for: observation(revision: 8, page: 1, text: "new revision text")) else {
            return XCTFail("a revision change must reload even a dirty draft")
        }
    }

    func test_pageChangeReloads() {
        let policy = TranscriptDraftPolicy(
            loadedRevisionID: 7, loadedPageID: 1, baselineText: "page one", draftText: "page one")
        guard case .reload("page two") =
                policy.decision(for: observation(revision: 7, page: 2, text: "page two")) else {
            return XCTFail("a page change must reload")
        }
    }

    func test_noChangePreserves() {
        let policy = TranscriptDraftPolicy(
            loadedRevisionID: 7, loadedPageID: 1, baselineText: "same", draftText: "same")
        guard case .preserve = policy.decision(for: observation(revision: 7, page: 1, text: "same")) else {
            return XCTFail("no change must preserve the draft")
        }
    }

    func test_dirtyDraftWithUnchangedPersistedTextPreserves() {
        let policy = TranscriptDraftPolicy(
            loadedRevisionID: 7, loadedPageID: 1, baselineText: "same", draftText: "user is typ")
        guard case .preserve = policy.decision(for: observation(revision: 7, page: 1, text: "same")) else {
            return XCTFail("typing alone must not trigger a reload")
        }
    }

    // MARK: - EnqueueOutcome (accurate batch reporting)

    func test_failuresAreReportedNotSwallowed() {
        let outcome = EnqueueOutcome.report(
            enqueued: 2, alreadyQueued: 1,
            failures: ["page 3: constraint error", "page 4: disk full"],
            providerName: "OpenAI", modelID: "gpt-4o")
        XCTAssertEqual(outcome.enqueued, 2)
        XCTAssertEqual(outcome.alreadyQueued, 1)
        XCTAssertEqual(outcome.failures.count, 2)
        XCTAssertEqual(outcome.activityTitle, "OCR queue incomplete")
        XCTAssertTrue(outcome.activityDetail.contains("2 queued"),
                      "detail must report the queued count, got: \(outcome.activityDetail)")
        XCTAssertTrue(outcome.activityDetail.contains("1 already queued"))
        XCTAssertTrue(outcome.activityDetail.contains("2 failed"))
        XCTAssertTrue(outcome.activityDetail.contains("constraint error"))
        XCTAssertTrue(outcome.activityDetail.contains("disk full"))
    }

    func test_allDeduplicatedIsAnAccurateZeroNotSuccess() {
        let outcome = EnqueueOutcome.report(
            enqueued: 0, alreadyQueued: 3, failures: [],
            providerName: "OpenAI", modelID: "gpt-4o")
        XCTAssertEqual(outcome.enqueued, 0)
        XCTAssertEqual(outcome.activityTitle, "OCR skipped")
        XCTAssertTrue(outcome.activityDetail.contains("3 requested page(s)"))
    }

    func test_normalQueuedReportMentionsDeduplicatedPages() {
        let outcome = EnqueueOutcome.report(
            enqueued: 4, alreadyQueued: 1, failures: [],
            providerName: "OpenAI", modelID: "gpt-4o")
        XCTAssertEqual(outcome.activityTitle, "OCR queued")
        XCTAssertTrue(outcome.activityDetail.contains("4 page(s)"))
        XCTAssertTrue(outcome.activityDetail.contains("1 additional page(s) were already queued"))
    }

    func test_fullSuccessReportHasNoDeduplicatedMention() {
        let outcome = EnqueueOutcome.report(
            enqueued: 2, alreadyQueued: 0, failures: [],
            providerName: "OpenAI", modelID: "gpt-4o")
        XCTAssertEqual(outcome.activityTitle, "OCR queued")
        XCTAssertFalse(outcome.activityDetail.contains("already queued"))
    }
}
