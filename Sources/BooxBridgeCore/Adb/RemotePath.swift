// pattern: Functional Core

import Foundation

public enum RemotePathError: Error, Equatable, Sendable, CustomStringConvertible {
    case empty
    case notAbsolute(String)
    case traversalComponent(String)
    case nulByte(String)
    case escapesRoot(root: String, path: String)
    case emptyComponent(String)

    public var description: String {
        switch self {
        case .empty: return "remote path is empty"
        case .notAbsolute(let p): return "remote path is not absolute: \(p)"
        case .traversalComponent(let p): return "remote path contains a traversal component: \(p)"
        case .nulByte(let p): return "remote path contains a NUL byte: \(p)"
        case .escapesRoot(let root, let path): return "remote path \(path) escapes configured root \(root)"
        case .emptyComponent(let p): return "remote path has an empty component: \(p)"
        }
    }
}

/// A validated, normalized absolute POSIX path on the device.
/// Components are stored decoded; `raw` is the canonical "/a/b" spelling.
public struct RemotePath: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let components: [String]

    public init(_ raw: String) throws {
        guard !raw.isEmpty else { throw RemotePathError.empty }
        guard raw.hasPrefix("/") else { throw RemotePathError.notAbsolute(raw) }
        // NUL is the one byte a POSIX path can never contain. Newlines and
        // tabs are legal filename bytes and survive every transport here:
        // listings are NUL-delimited and shell quoting escapes everything.
        guard !raw.contains("\0") else { throw RemotePathError.nulByte(raw) }

        var parts: [String] = []
        for component in raw.split(separator: "/", omittingEmptySubsequences: true) {
            let part = String(component)
            guard part != "." else { continue } // normalize away
            guard part != ".." else { throw RemotePathError.traversalComponent(raw) }
            parts.append(part)
        }
        // A path that is all separators ("/" or "///") addresses the root
        // itself; we never operate on the root directly.
        guard !parts.isEmpty else { throw RemotePathError.emptyComponent(raw) }
        self.components = parts
    }

    private init(root: RemotePath, appending component: String) {
        self.components = root.components + [component]
    }

    public var raw: String { "/" + components.joined(separator: "/") }
    public var description: String { raw }

    /// Parent path; nil at the top level (a single component under "/").
    public var parent: RemotePath? {
        guard components.count > 1 else { return nil }
        return try? RemotePath("/" + components.dropLast().joined(separator: "/"))
    }

    public var lastComponent: String { components.last! }

    /// True when this path is `root` itself or lies underneath it.
    public func isWithin(_ root: RemotePath) -> Bool {
        components.starts(with: root.components)
    }

    /// Require containment, throwing otherwise.
    public func requireWithin(_ root: RemotePath) throws {
        guard isWithin(root) else {
            throw RemotePathError.escapesRoot(root: root.raw, path: raw)
        }
    }

    public func appending(_ component: String) throws -> RemotePath {
        guard !component.isEmpty else { throw RemotePathError.emptyComponent(component) }
        guard !component.contains("\0") else { throw RemotePathError.nulByte(component) }
        guard component != ".", component != "..", !component.contains("/") else {
            throw RemotePathError.traversalComponent(component)
        }
        return RemotePath(root: self, appending: component)
    }
}

public enum ShellQuoting {
    /// POSIX single-quote escaping for a remote shell argument:
    /// `'` → `'\''`, wrapped in single quotes. Safe for every byte except
    /// NUL (rejected upstream by RemotePath).
    public static func quote(_ argument: String) -> String {
        guard !argument.contains("'") else {
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return "'\(argument)'"
    }

    /// Quote validated remote paths for use in a remote command string.
    public static func quote(_ path: RemotePath) -> String {
        quote(path.raw)
    }
}
