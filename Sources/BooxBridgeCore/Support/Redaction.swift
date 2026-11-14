// pattern: Functional Core
// Key redaction for logs, errors, and diagnostics. Provider API keys must
// never reach stderr, the catalog, or exception descriptions. Redaction is
// applied defensively at every boundary that formats an error or log line.

import Foundation

public enum Redaction {
    /// Marker used when a secret is removed from text.
    public static let placeholder = "[redacted]"

    /// Replace every occurrence of `secret` with the placeholder. Empty or
    /// whitespace-only secrets are left alone (nothing to redact).
    public static func redact(_ text: String, secrets: [String]) -> String {
        var result = text
        for secret in secrets where !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = result.replacingOccurrences(of: secret, with: placeholder)
        }
        return result
    }

    /// Extract a bearer/api key from an Authorization header value so it can
    /// be added to the redaction set before formatting.
    public static func secrets(inAuthorizationHeader value: String) -> [String] {
        let parts = value.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return [value].filter { !$0.isEmpty } }
        return [String(parts[1])]
    }

    /// Format an HTTP failure without echoing response bodies, which can
    /// contain echo-backs of the request (and therefore the key).
    public static func httpFailureSummary(status: Int, urlHost: String) -> String {
        "request to \(urlHost) failed with status \(status)"
    }
}
