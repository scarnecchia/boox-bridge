// pattern: Functional Core
// Pure ownership state machine for the OCR drain task. The environment keeps
// exactly one drain owner at a time; a task's completion is only trusted to
// release or hand over ownership when its generation still matches, so a
// cancelled-but-still-draining task can never clear a newer task's handle,
// and a start request while a drain is live cancels the live task and chains
// the new drain onto its actual termination (no overlapping runners, so the
// non-atomic nextQueuedJob→mark-running claim in the core store can never be
// raced by two in-process runners).

struct OCRDrainOwnership: Equatable, Sendable {
    private(set) var activeGeneration: Int?
    private(set) var pendingRestart: Bool = false
    private var lastIssuedGeneration: Int = 0

    enum StartDecision: Equatable, Sendable {
        /// Spawn a drain task for this generation.
        case launch(generation: Int)
        /// Cancel the live task of this generation; the new drain launches
        /// when that task's completion reports finish for the same generation.
        case cancelLive(generation: Int)
    }

    enum FinishDecision: Equatable, Sendable {
        /// Ownership fully released; nothing is draining.
        case release
        /// The finished task's generation owned the drain and a start was
        /// requested meanwhile: spawn the chained drain for this generation.
        case relaunch(generation: Int)
        /// A late or duplicate completion of an older generation — the current
        /// owner must stay untouched.
        case ignoreStale(generation: Int)
    }

    var isOwned: Bool { activeGeneration != nil }

    /// The generation whose task should be cancelled right now, if any.
    /// Ownership is retained until the task actually finishes.
    func generationToCancel() -> Int? { activeGeneration }

    mutating func requestStart() -> StartDecision {
        if let live = activeGeneration {
            pendingRestart = true
            return .cancelLive(generation: live)
        }
        let generation = nextGeneration()
        activeGeneration = generation
        return .launch(generation: generation)
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
