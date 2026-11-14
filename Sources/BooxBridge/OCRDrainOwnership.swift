// pattern: Functional Core
// Pure ownership state machine for the OCR drain task. The environment keeps
// exactly one drain owner at a time; a task's completion is only trusted to
// release or hand over ownership when its generation still matches, so a
// cancelled-but-still-draining task can never clear a newer task's handle.
//
// Transition table (the environment applies these decisions; no I/O here):
//   requestStart while idle  → launch a fresh generation's drain.
//   requestStart while live  → arm a chained restart and keep the live task
//                              running untouched. The core drain loop
//                              re-claims the queue on every iteration, so it
//                              normally picks newly enqueued jobs up itself;
//                              when it was already finishing, the chained
//                              drain launches on the live task's actual
//                              termination. A start request never cancels
//                              in-flight work: cancelling would abort a
//                              request that was already sent (recorded
//                              terminally failed by the core, its billed
//                              request wasted).
//   requestCancel while idle → no-op.
//   requestCancel while live → disarm any armed restart and cancel the live
//                              task. Ownership is retained until the task
//                              actually reports finish, so a user stop can
//                              never chain into further paid OCR work, and
//                              a stale completion still resolves safely.
//   taskDidFinish (stale)    → ignore; the current owner stays untouched.
//   taskDidFinish (owner)    → relaunch only if a restart is still armed,
//                              otherwise release.

struct OCRDrainOwnership: Equatable, Sendable {
    private(set) var activeGeneration: Int?
    private(set) var pendingRestart: Bool = false
    private var lastIssuedGeneration: Int = 0

    enum StartDecision: Equatable, Sendable {
        /// Spawn a drain task for this generation.
        case launch(generation: Int)
        /// A drain is already live: a restart is armed and the live task keeps
        /// running untouched. The chained drain launches when the live task's
        /// completion reports finish for its own generation — unless the
        /// restart is disarmed first by requestCancel().
        case restartArmed(generation: Int)
    }

    enum CancelDecision: Equatable, Sendable {
        /// No drain is live; there is nothing to cancel.
        case idle
        /// Cancel the live task of this generation now. Any armed restart is
        /// disarmed; ownership is retained until the task actually reports
        /// finish so its (possibly stale) completion resolves safely.
        case cancel(generation: Int)
    }

    enum FinishDecision: Equatable, Sendable {
        /// Ownership fully released; nothing is draining.
        case release
        /// The finished task's generation owned the drain and a start was
        /// requested meanwhile (and not cancelled since): spawn the chained
        /// drain for this generation.
        case relaunch(generation: Int)
        /// A late or duplicate completion of an older generation — the current
        /// owner must stay untouched.
        case ignoreStale(generation: Int)
    }

    var isOwned: Bool { activeGeneration != nil }

    /// The generation whose task may be cancelled right now (the live owner),
    /// if any. Ownership is retained until the task actually finishes.
    func generationToCancel() -> Int? { activeGeneration }

    mutating func requestStart() -> StartDecision {
        if let live = activeGeneration {
            pendingRestart = true
            return .restartArmed(generation: live)
        }
        let generation = nextGeneration()
        activeGeneration = generation
        return .launch(generation: generation)
    }

    mutating func requestCancel() -> CancelDecision {
        guard let live = activeGeneration else { return .idle }
        pendingRestart = false
        return .cancel(generation: live)
    }

    mutating func taskDidFinish(generation: Int) -> FinishDecision {
        guard generation == activeGeneration else {
            return .ignoreStale(generation: generation)
        }
        activeGeneration = nil
        if pendingRestart {
            let generation = nextGeneration()
            activeGeneration = generation
            pendingRestart = false
            return .relaunch(generation: generation)
        }
        return .release
    }

    private mutating func nextGeneration() -> Int {
        lastIssuedGeneration += 1
        return lastIssuedGeneration
    }
}
