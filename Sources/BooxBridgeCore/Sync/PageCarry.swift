// pattern: Functional Core (planner) / Imperative Shell (fingerprint seam)

import Foundation

/// Per-page content identity for import carry-over. Adapters render each
/// page deterministically and hash the result; tests inject fakes. Page
/// indices are zero-based.
public protocol PageFingerprinting: Sendable {
    func sha256PerPage(fileAt url: URL) throws -> [Int: String]
}

/// Matches pages between the previous and next revision of the same document
/// so transcription text carries over pages whose rendered content is
/// unchanged. Matching is by content, not position: prepended or inserted
/// pages keep the earlier pages' text, and each previous page is consumed at
/// most once so duplicated blank pages do not double-match.
public enum PageCarry {
    public struct Match: Equatable, Sendable {
        public let newPage: Int
        public let oldPage: Int

        public init(newPage: Int, oldPage: Int) {
            self.newPage = newPage
            self.oldPage = oldPage
        }
    }

    /// Greedy first-match: new pages in ascending order claim the lowest
    /// still-unclaimed previous page with an identical hash.
    public static func plan(old: [Int: String], new: [Int: String]) -> [Match] {
        var byHash: [String: [Int]] = [:]
        for (index, hash) in old.sorted(by: { $0.key < $1.key }) {
            byHash[hash, default: []].append(index)
        }
        var matches: [Match] = []
        for (newIndex, hash) in new.sorted(by: { $0.key < $1.key }) {
            guard var candidates = byHash[hash], !candidates.isEmpty else { continue }
            let oldIndex = candidates.removeFirst()
            byHash[hash] = candidates
            matches.append(Match(newPage: newIndex, oldPage: oldIndex))
        }
        return matches
    }
}
