// pattern: Functional Core (decision-type regression tests)

import XCTest
@testable import BooxBridge

/// Regression tests for the OCR drain ownership state machine. Before the
/// generation token, cancelOCRDrain cleared the task handle immediately and
/// the finished task's unconditional cleanup cleared whatever handle was
/// current — a cancelled-but-still-draining task could erase a newer drain's
/// ownership, allowing overlapping runners to race the store's non-atomic
/// queue claim.
final class OCRDrainOwnershipTests: XCTestCase {
    func test_cancelRetainsOwnershipUntilActualTermination() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("first start must launch")
        }
        // Cancellation keeps ownership: the in-flight request may still be
        // draining, so a second runner must not start yet.
        XCTAssertEqual(ownership.generationToCancel(), first)
        XCTAssertTrue(ownership.isOwned, "cancel must not release ownership")

        guard case .release = ownership.taskDidFinish(generation: first) else {
            return XCTFail("the owning generation's finish must release")
        }
        XCTAssertFalse(ownership.isOwned)
        XCTAssertNil(ownership.generationToCancel())
    }

    func test_staleCompletionNeverClearsNewerOwner() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("first start must launch")
        }
        guard case .cancelLive(let cancelled) = ownership.requestStart() else {
            return XCTFail("start while live must cancel the live generation")
        }
        XCTAssertEqual(cancelled, first)

        // The old task terminates; a start was requested meanwhile, so its
        // completion chains the relaunch instead of releasing into an idle
        // state that would double-claim.
        guard case .relaunch(let second) = ownership.taskDidFinish(generation: first) else {
            return XCTFail("finish with a pending restart must relaunch")
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

    func test_startWhileLiveChainsRestartOnActualTermination() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("first start must launch")
        }
        // While the first generation owns the drain, no second launch may be
        // handed out — overlapping runners would double-claim queued jobs.
        guard case .cancelLive = ownership.requestStart() else {
            return XCTFail("second start while live must cancel, never launch")
        }
        guard case .relaunch(let second) = ownership.taskDidFinish(generation: first) else {
            return XCTFail("chained relaunch must wait for actual termination")
        }
        XCTAssertNotEqual(second, first)
        guard case .release = ownership.taskDidFinish(generation: second) else {
            return XCTFail("chained drain finishes normally")
        }
        XCTAssertFalse(ownership.isOwned)
    }

    func test_finishWithoutPendingStartReleases() {
        var ownership = OCRDrainOwnership()
        guard case .launch(let first) = ownership.requestStart() else {
            return XCTFail("start must launch")
        }
        guard case .release = ownership.taskDidFinish(generation: first) else {
            return XCTFail("finish with no pending restart must release")
        }
        XCTAssertFalse(ownership.isOwned)
    }

    func test_cancelBeforeAnyStartIsNoop() {
        var ownership = OCRDrainOwnership()
        XCTAssertNil(ownership.generationToCancel())
        XCTAssertFalse(ownership.isOwned)
    }
}
