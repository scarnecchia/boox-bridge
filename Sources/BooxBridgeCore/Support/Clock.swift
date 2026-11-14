// pattern: Imperative Shell (seam only)
// Injectable clock so queue/backoff logic is deterministic in tests. The
// production adapter reads wall time; nothing in the core reads the system
// clock directly.

import Foundation

public protocol WallClock: Sendable {
    func now() -> Date
    func sleep(for duration: TimeInterval) async throws
}

public struct SystemClock: WallClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for duration: TimeInterval) async throws {
        if duration > 0 {
            try await Task.sleep(for: .seconds(duration))
        }
    }
}

/// Fixed clock for tests and deterministic scenario mode. State changes
/// happen in synchronous lock-guarded helpers; the async `sleep` only calls
/// through, because NSLock is unavailable in async contexts.
public final class ManualClock: WallClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var slept: [TimeInterval] = []

    public init(start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    public func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func sleep(for duration: TimeInterval) async throws {
        advance(duration)
    }

    private func advance(_ duration: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        slept.append(duration)
        current = current.addingTimeInterval(duration)
    }

    public var recordedSleeps: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return slept
    }
}
