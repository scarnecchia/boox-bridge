// pattern: Functional Core (decision-type regression tests)

import XCTest
@testable import BooxBridge

/// Regression tests for the OCR drain ownership state machine.
///
/// Round-2 transition-table contract:
/// - Before this change a start request while a drain was live returned
///   `.cancelLive` and the environment cancelled the in-flight task; the core
///   recorded the interrupted page as terminally failed and the billed
///   request was wasted. Now `requestStart` arms a chained restart and the
///   live task keeps running.
/// - Before this change an explicit Cancel only cancelled the current task
///   and never cleared the armed restart: start → start (armed) → cancel →
///   finish still relaunched and sent paid OCR work after the user's stop.
///   Now `requestCancel` disarms the restart and ownership is retained until
///   the task actually reports finish.
final class OCRDrainOwnershipTests: XCTestCase {
    func test_startWhileLiveArmsRestartWithoutCancellingInFlightWork() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("first start must launch")
        }
        // The live task keeps running: no cancellation is handed out, and
        // ownership stays with the in-flight generation.
        guard case .restartArmed(let live) = ownership.requestStart() else {
            return XCTFail("start while live must arm a restart, never cancel the live task")
        }
        XCTAssertEqual(live, first)
        XCTAssertEqual(ownership.generationToCancel(), first,
                       "the in-flight generation must stay the live owner")
        XCTAssertTrue(ownership.isOwned)

        // Exactly one relaunch when the live drain actually finishes.
        guard case .relaunch(let second) = ownership.taskDidFinish(generation: first) else {
            return XCTFail("finish with an armed restart must relaunch exactly once")
        }
        XCTAssertNotEqual(second, first)
        guard case .release = ownership.taskDidFinish(generation: second) else {
            return XCTFail("the chained drain finishes normally")
        }
        XCTAssertFalse(ownership.isOwned)
    }

    func test_explicitCancelDisarmsRestartAndReleasesOnActualTermination() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("start must launch")
        }
        guard case .restartArmed = ownership.requestStart() else {
            return XCTFail("second start must arm a restart")
        }
        // The user's stop wins: the armed restart is disarmed and the live
        // task is cancelled — but ownership is retained until termination so
        // the completion still resolves safely.
        guard case .cancel(let cancelled) = ownership.requestCancel() else {
            return XCTFail("cancel while live must hand out the generation to cancel")
        }
        XCTAssertEqual(cancelled, first)
        XCTAssertTrue(ownership.isOwned, "cancel must retain ownership until the task actually finishes")
        XCTAssertEqual(ownership.generationToCancel(), first)

        guard case .release = ownership.taskDidFinish(generation: first) else {
            return XCTFail("a cancelled, disarmed finish must release — never relaunch paid work")
        }
        XCTAssertFalse(ownership.isOwned)
        XCTAssertNil(ownership.generationToCancel(), "generation must be released on termination")
    }

    func test_cancelWhileIdleIsNoop() {
        var ownership = OCRDrainOwnership()
        guard case .idle = ownership.requestCancel() else {
            return XCTFail("cancel with no drain must be a no-op")
        }
        XCTAssertFalse(ownership.isOwned)
    }

    func test_cancelThenStartWhileStillLiveChainsRestartOnLastAction() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("start must launch")
        }
        guard case .restartArmed = ownership.requestStart() else {
            return XCTFail("second start must arm a restart")
        }
        guard case .cancel = ownership.requestCancel() else {
            return XCTFail("cancel must disarm")
        }
        // The user restarts before the cancelled task actually finished: the
        // last action wins, so the finish chains a relaunch again.
        guard case .restartArmed = ownership.requestStart() else {
            return XCTFail("a start after cancel while still live must re-arm the restart")
        }
        guard case .relaunch = ownership.taskDidFinish(generation: first) else {
            return XCTFail("finish after a re-armed restart must relaunch")
        }
    }

    func test_staleCompletionNeverClearsNewerOwner() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("first start must launch")
        }
        guard case .restartArmed = ownership.requestStart() else {
            return XCTFail("start while live must arm a restart")
        }
        guard case .relaunch(let second) = ownership.taskDidFinish(generation: first) else {
            return XCTFail("finish with an armed restart must relaunch")
        }
        XCTAssertTrue(ownership.isOwned)
        XCTAssertEqual(ownership.generationToCancel(), second)

        // A late/duplicate completion of the old generation must leave the
        // newer owner completely untouched.
        guard case .ignoreStale(let stale) = ownership.taskDidFinish(generation: first) else {
            return XCTFail("old-generation finish must be ignored as stale")
        }
        XCTAssertEqual(stale, first)
        XCTAssertTrue(ownership.isOwned)
        XCTAssertEqual(ownership.generationToCancel(), second, "stale completion clobbered the newer owner")
    }

    func test_finishWithoutPendingStartReleases() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("start must launch")
        }
        guard case .release = ownership.taskDidFinish(generation: first) else {
            return XCTFail("finish with no armed restart must release")
        }
        XCTAssertFalse(ownership.isOwned)
    }

    func test_cancelBeforeAnyStartIsNoop() {
        var ownership = OCRDrainOwnership()
        XCTAssertNil(ownership.generationToCancel())
        XCTAssertFalse(ownership.isOwned)
        guard case .idle = ownership.requestCancel() else {
            return XCTFail("cancel before any start must be a no-op")
        }
    }
}
