// pattern: Imperative Shell
// Process execution seam. The production runner spawns real OS processes
// with explicit argv (never /bin/sh -c), drains both output pipes
// concurrently under byte caps, enforces timeouts, and cleans up on
// cancellation. Tests drive the same interface with a fixture adb script.

import Foundation

#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

public struct ProcessRequest: Sendable {
    public var executable: URL
    public var arguments: [String]
    /// Kill the process (interrupt, then terminate) after this many seconds.
    public var timeout: TimeInterval
    /// Per-stream capture cap. Extra bytes are dropped and flagged.
    public var maxOutputBytes: Int

    public init(executable: URL, arguments: [String], timeout: TimeInterval = 30, maxOutputBytes: Int = 8 * 1024 * 1024) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
    }
}

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public let stdoutTruncated: Bool
    public let stderrTruncated: Bool

    public var succeeded: Bool { exitCode == 0 }

    public init(exitCode: Int32, stdout: Data, stderr: Data, stdoutTruncated: Bool = false, stderrTruncated: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }
}

public enum ProcessFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case spawnFailed(String)
    case timedOut(executable: String)
    case cancelled
    case nonZeroExit(exitCode: Int32, stderrSummary: String)

    public var description: String {
        switch self {
        case .spawnFailed(let why): return "failed to launch process: \(why)"
        case .timedOut(let exe): return "process \(exe) timed out"
        case .cancelled: return "process execution cancelled"
        case .nonZeroExit(let code, let summary): return "process exited with status \(code)\(summary.isEmpty ? "" : ": \(summary)")"
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ request: ProcessRequest) async throws -> ProcessResult
}

public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(_ request: ProcessRequest) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = request.executable
        process.arguments = request.arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Environment is inherited; adb locates its server via argv[0] and
        // $HOME. No shell profile is ever sourced and no shell is involved.

        let stdout = CappedBuffer(maxBytes: request.maxOutputBytes)
        let stderr = CappedBuffer(maxBytes: request.maxOutputBytes)
        let drains = DrainState()
        attach(collector: stdout, to: stdoutPipe, drain: drains, isStdout: true)
        attach(collector: stderr, to: stderrPipe, drain: drains, isStdout: false)

        do {
            try process.run()
        } catch {
            closePipes(stdoutPipe, stderrPipe)
            throw ProcessFailure.spawnFailed(error.localizedDescription)
        }

        let box = ProcessBox(process)
        box.installTerminationHandler()
        let watchdog = KillWatchdog()

        // A detached watchdog owns the deadline: when it fires it kills the
        // process and records WHY. The main path makes exactly one,
        // group-free await on termination — no teardown can deadlock on a
        // wait that ignores cancellation.
        let timeout = request.timeout
        let watchdogTask = Task.detached { [box, watchdog, timeout] in
            guard timeout > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return // cancelled — the process exited first
            }
            watchdog.markTimedOut()
            box.terminate()
        }

        await withTaskCancellationHandler {
            await box.termination()
        } onCancel: {
            watchdog.markCancelled()
            Task.detached { box.terminate() }
        }
        watchdogTask.cancel()
        // Drain to EOF before closing: termination can fire while handlers
        // still hold undelivered output (a race that truncates results).
        drains.waitForEOF(timeout: 2.0)
        closePipes(stdoutPipe, stderrPipe)

        if Task.isCancelled || watchdog.reason == .cancelled {
            throw ProcessFailure.cancelled
        }
        if watchdog.reason == .timedOut {
            throw ProcessFailure.timedOut(executable: request.executable.lastPathComponent)
        }

        let code = box.exitCode ?? -1
        return ProcessResult(
            exitCode: code,
            stdout: stdout.data,
            stderr: stderr.data,
            stdoutTruncated: stdout.truncated,
            stderrTruncated: stderr.truncated
        )
    }

    private func attach(collector: CappedBuffer, to pipe: Pipe, drain: DrainState, isStdout: Bool) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                drain.markEOF(isStdout: isStdout)
            } else {
                collector.feed(chunk)
            }
        }
    }

    private func closePipes(_ pipes: Pipe...) {
        for pipe in pipes {
            pipe.fileHandleForReading.readabilityHandler = nil
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
    }
}

// MARK: - Helpers

/// Tracks EOF on both output streams so results are only finalized after
/// every buffered byte has been captured.
final class DrainState: @unchecked Sendable {
    private let condition = NSCondition()
    private var stdoutEOF = false
    private var stderrEOF = false

    func markEOF(isStdout: Bool) {
        condition.lock()
        if isStdout { stdoutEOF = true } else { stderrEOF = true }
        condition.broadcast()
        condition.unlock()
    }

    func waitForEOF(timeout: TimeInterval) {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !(stdoutEOF && stderrEOF) && Date() < deadline {
            _ = condition.wait(until: deadline)
        }
    }
}

/// Records why a process was killed (timeout vs caller cancellation) so the
/// post-termination path can report the right failure. First marker wins.
final class KillWatchdog: @unchecked Sendable {
    enum Reason {
        case timedOut
        case cancelled
    }

    private let lock = NSLock()
    private var _reason: Reason?

    var reason: Reason? {
        lock.lock(); defer { lock.unlock() }
        return _reason
    }

    func markTimedOut() {
        lock.lock()
        if _reason == nil { _reason = .timedOut }
        lock.unlock()
    }

    func markCancelled() {
        lock.lock()
        if _reason == nil { _reason = .cancelled }
        lock.unlock()
    }
}

/// Lock-guarded byte collector with a hard cap. readabilityHandler fires on
/// a Dispatch queue, so all state is lock-protected.
final class CappedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let maxBytes: Int
    private(set) var truncated = false

    init(maxBytes: Int) {
        self.maxBytes = maxBytes
    }

    func feed(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !truncated else { return }
        let remaining = maxBytes - buffer.count
        guard remaining > 0 else { truncated = true; return }
        if chunk.count <= remaining {
            buffer.append(chunk)
        } else {
            buffer.append(chunk.prefix(remaining))
            truncated = true
        }
    }

    var data: Data {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}

/// Process is not Sendable; every access is funneled through this box. The
/// termination handler records the exit status and resumes waiters — that
/// works for natural exit, timeout kill, and cancellation kill alike.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var _exitCode: Int32?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ process: Process) {
        self.process = process
    }

    func installTerminationHandler() {
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.lock.lock()
            self._exitCode = finished.terminationStatus
            let toResume = self.waiters
            self.waiters = []
            self.lock.unlock()
            for continuation in toResume { continuation.resume() }
        }
    }

    var exitCode: Int32? {
        lock.lock(); defer { lock.unlock() }
        return _exitCode
    }

    /// Suspend until the process has terminated (idempotent).
    func termination() async {
        if hasTerminated() { return }
        await withCheckedContinuation { continuation in
            enqueueWaiter(continuation)
        }
    }

    private func hasTerminated() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _exitCode != nil
    }

    private func enqueueWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if _exitCode != nil {
            lock.unlock()
            continuation.resume()
            return
        }
        waiters.append(continuation)
        lock.unlock()
    }

    /// Interrupt, then force-kill. Safe to call from any thread, multiple
    /// times, and after exit.
    ///
    /// Signals are delivered with kill(2), NOT Process.interrupt/terminate:
    /// on some hosts the corelibs implementations fail to deliver any
    /// signal, which would leave a hung adb running for its full natural
    /// lifetime. SIGINT first (a well-behaved adb gets a chance to exit
    /// cleanly), SIGKILL after the grace period — SIGKILL cannot be ignored.
    func terminate() {
        lock.lock()
        let pid = Int32(process.processIdentifier)
        let running = _exitCode == nil && process.isRunning
        lock.unlock()
        guard running, pid > 0 else { return }

        _ = kill(pid, SIGINT)
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            lock.lock(); let still = _exitCode == nil && process.isRunning; lock.unlock()
            if !still { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock(); let stillRunning = _exitCode == nil && process.isRunning; lock.unlock()
        if stillRunning {
            _ = kill(pid, SIGKILL)
        }
    }
}
