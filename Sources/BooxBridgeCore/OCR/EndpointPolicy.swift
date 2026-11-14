// pattern: Functional Core
// Endpoint security policy: HTTPS everywhere except explicit loopback HTTP
// for local endpoints; no userinfo; no credentials in query strings;
// redirects may never cross origins (the key must not travel to another
// host, and a redirect must never silently downgrade the scheme).

import Foundation

public enum EndpointVerdict: Equatable, Sendable {
    case allowed
    case rejected(reason: String)
}

public enum EndpointPolicy {
    static let loopbackHosts: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"]
    static let credentialQueryNames: Set<String> = [
        "key", "apikey", "api_key", "token", "access_token", "secret", "password", "signature",
    ]

    public static func validate(url: URL) -> EndpointVerdict {
        guard let scheme = url.scheme?.lowercased() else {
            return .rejected(reason: "endpoint URL has no scheme")
        }
        if let user = url.user, !user.isEmpty {
            return .rejected(reason: "endpoint URL must not embed credentials in the userinfo")
        }
        if let password = url.password, !password.isEmpty {
            return .rejected(reason: "endpoint URL must not embed a password")
        }
        if let query = url.query, !query.isEmpty {
            let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            for item in names where credentialQueryNames.contains(item.name.lowercased()) {
                return .rejected(reason: "endpoint URL must not carry '\(item.name)' in its query")
            }
        }
        switch scheme {
        case "https":
            return .allowed
        case "http":
            guard let host = url.hostname(), loopbackHosts.contains(host.lowercased()) else {
                return .rejected(reason: "plain HTTP is only allowed for loopback endpoints (localhost)")
            }
            return .allowed
        default:
            return .rejected(reason: "endpoint must use https (or http on loopback), not '\(scheme)'")
        }
    }

    /// May a redirect from `from` to `to` be followed with our Authorization
    /// header attached? Same-origin (host AND upgraded-or-equal scheme)
    /// only; anything else must be surfaced as an error, never followed.
    public static func redirectAllowed(from: URL, to: URL) -> Bool {
        guard let toScheme = to.scheme?.lowercased() else { return false }
        guard toScheme == "https" else { return false }
        guard let fromHost = from.hostname(), let toHost = to.hostname() else { return false }
        return fromHost.lowercased() == toHost.lowercased()
    }
}

extension URL {
    /// Normalized host without brackets (IPv6) or port.
    func hostname() -> String? {
        if let host = self.host { return host }
        // URLComponents handles bracketed IPv6 more reliably.
        return URLComponents(url: self, resolvingAgainstBaseURL: false)?.host
    }
}
