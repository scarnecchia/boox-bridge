// pattern: Functional Core

import Foundation

public enum PlatformPolicy {
    /// The minimum supported macOS version, as "major.minor".
    public static let minimumMacOS = OSVersion(major: 26, minor: 1)

    /// Parse "26.1", "26.1.2", or "14" style version strings. Returns nil for
    /// non-numeric components or negatives — callers must treat unparsable
    /// versions as unsupported rather than guessing.
    public static func parseVersion(_ string: String) -> OSVersion? {
        let parts = string.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // Digits only: "26", "26.1", "26.1.2" parse; "-1", "+1", "1a" do not.
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        return OSVersion(major: numbers[0], minor: numbers.count > 1 ? numbers[1] : 0)
    }

    /// True when `candidate` meets or exceeds `minimum`.
    public static func isSupported(_ candidate: OSVersion, minimum: OSVersion = PlatformPolicy.minimumMacOS) -> Bool {
        if candidate.major != minimum.major { return candidate.major > minimum.major }
        return candidate.minor >= minimum.minor
    }

    /// Diagnose a runtime-reported OS version string (e.g. from
    /// ProcessInfo). Nil input or unparsable input is "unknown", which
    /// callers must surface as unsupported, never as a pass.
    public static func checkOperatingSystem(_ raw: String?) -> OSStatus {
        guard let raw, let version = parseVersion(raw) else {
            return .unknownVersion(raw)
        }
        return isSupported(version) ? .supported(version) : .unsupported(version, minimum: minimumMacOS)
    }
}

public struct OSVersion: Equatable, Sendable, Comparable {
    public let major: Int
    public let minor: Int

    public init(major: Int, minor: Int) {
        self.major = major
        self.minor = minor
    }

    public static func < (lhs: OSVersion, rhs: OSVersion) -> Bool {
        (lhs.major, lhs.minor) < (rhs.major, rhs.minor)
    }

    public var description: String { "\(major).\(minor)" }
}

public enum OSStatus: Equatable, Sendable {
    case supported(OSVersion)
    case unsupported(OSVersion, minimum: OSVersion)
    case unknownVersion(String?)

    public var isSupported: Bool {
        if case .supported = self { return true }
        return false
    }

    public var userMessage: String {
        switch self {
        case .supported(let v):
            return "macOS \(v) is supported."
        case .unsupported(let v, let minimum):
            return "Boox Bridge requires macOS \(minimum) or newer; this Mac reports macOS \(v)."
        case .unknownVersion(let raw):
            return "Could not determine the macOS version\(raw.map { " (reported: \($0))" } ?? ""). Boox Bridge requires macOS \(PlatformPolicy.minimumMacOS) or newer."
        }
    }
}
