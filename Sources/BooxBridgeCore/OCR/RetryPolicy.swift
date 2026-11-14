// pattern: Functional Core
// Retry classification for provider responses. Bounded exponential backoff
// honoring Retry-After; permanent 4xx never retries; success is not decided
// here (the caller decodes the body).

import Foundation

public struct RetryLimits: Sendable {
    public var maxAttempts: Int
    public var baseBackoffSeconds: TimeInterval
    public var maxBackoffSeconds: TimeInterval
    public var maxRetryAfterSeconds: TimeInterval

    public init(maxAttempts: Int = 4,
                baseBackoffSeconds: TimeInterval = 2,
                maxBackoffSeconds: TimeInterval = 120,
                maxRetryAfterSeconds: TimeInterval = 300) {
        self.maxAttempts = maxAttempts
        self.baseBackoffSeconds = baseBackoffSeconds
        self.maxBackoffSeconds = maxBackoffSeconds
        self.maxRetryAfterSeconds = maxRetryAfterSeconds
    }
}

public enum RetryDecision: Equatable, Sendable {
    /// Retryable failure; wait this many seconds (already capped).
    case retryAfter(TimeInterval, reason: String)
    /// Permanent failure; surfaced verbatim, never retried.
    case fail(String)
}

public enum RetryPolicy {
    public static func decide(
        status: Int,
        retryAfterHeader: String?,
        attempt: Int,
        limits: RetryLimits = RetryLimits()
    ) -> RetryDecision {
        guard attempt < limits.maxAttempts else {
            return .fail("giving up after \(attempt) attempts (status \(status))")
        }
        switch status {
        case 429:
            let delay = min(parsedRetryAfter(retryAfterHeader) ?? backoff(attempt: attempt, limits: limits),
                            limits.maxRetryAfterSeconds)
            return .retryAfter(delay, reason: "rate limited (429)")
        case 408, 500, 502, 503, 504, 529:
            return .retryAfter(backoff(attempt: attempt, limits: limits),
                               reason: "transient server error (\(status))")
        case 401, 403:
            return .fail("authentication rejected (\(status)) — check the API key for this profile")
        case 400, 404, 405, 413, 415, 422:
            return .fail("request rejected (\(status)) — the model or endpoint likely does not accept image input for this profile")
        default:
            return .fail("unexpected status \(status)")
        }
    }

    /// Exponential backoff: base * 2^attempt, hard-capped.
    public static func backoff(attempt: Int, limits: RetryLimits) -> TimeInterval {
        let raw = limits.baseBackoffSeconds * pow(2, Double(max(0, attempt)))
        return min(raw, limits.maxBackoffSeconds)
    }

    static func parsedRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        // HTTP-date form: approximate from remaining seconds; nil if unparsable.
        if let date = httpDate(header) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    static func httpDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: string)
    }
}
