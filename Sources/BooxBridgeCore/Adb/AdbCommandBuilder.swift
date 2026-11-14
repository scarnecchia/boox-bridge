// pattern: Functional Core
// Pure construction of every adb argv array the app issues, plus the
// NUL-delimited remote listing parser.
//
// Two quoting regimes, never mixed:
//  - `adb shell <script>` sends the remaining argv JOINED WITH SPACES to a
//    real shell on the device. Every remote path inside such a script is
//    wrapped by ShellQuoting (POSIX single quotes). Filenames produced by
//    the script itself are only ever handled inside double quotes ("$1").
//  - `adb pull`/`adb push` are parsed locally by adb (sync protocol, no
//    shell), so paths pass as plain argv elements.

import Foundation

/// Every remote operation the app performs. There is deliberately no case
/// for deletion or renaming — remoteMutationPolicy tests assert the enum
/// stays mutation-free.
public enum AdbCommand: Equatable, Sendable {
    case version
    case devices
    case stat(remote: RemotePath, serial: String)
    case sha256(remote: RemotePath, serial: String)
    case listFiles(root: RemotePath, serial: String)
    case pull(remote: RemotePath, intoLocalDirectory: String, serial: String)
    case push(localPath: String, toRemote: RemotePath, serial: String)
    case makeDirectory(remote: RemotePath, serial: String)
    case deviceProperty(name: String, serial: String)
}

public enum AdbCommandBuilder {
    /// Build the local argv (never a shell string) for a command.
    public static func argv(for command: AdbCommand) -> [String] {
        switch command {
        case .version:
            return ["version"]
        case .devices:
            return ["devices", "-l"]
        case .stat(let remote, let serial):
            return scoped(serial, ["shell", "stat -c '%s|%Y|%F' -- " + ShellQuoting.quote(remote)])
        case .sha256(let remote, let serial):
            return scoped(serial, ["shell", "sha256sum -- " + ShellQuoting.quote(remote)])
        case .listFiles(let root, let serial):
            return scoped(serial, ["shell", listingScript(for: root)])
        case .pull(let remote, let localDirectory, let serial):
            return scoped(serial, ["pull", remote.raw, localDirectory])
        case .push(let localPath, let remote, let serial):
            return scoped(serial, ["push", localPath, remote.raw])
        case .makeDirectory(let remote, let serial):
            return scoped(serial, ["shell", "mkdir -p -- " + ShellQuoting.quote(remote)])
        case .deviceProperty(let name, let serial):
            return scoped(serial, ["shell", "getprop " + ShellQuoting.quote(name)])
        }
    }

    /// NUL-delimited listing: for each regular file under `root`, emit
    /// "size|mtime|kind<TAB>path" followed by a NUL byte. Metadata sits
    /// before the tab so the path may legally contain tabs, spaces,
    /// newlines, quotes, and leading hyphens.
    ///
    /// The inner sh -c script uses only double quotes, so it can be safely
    /// single-quoted by ShellQuoting inside the outer script.
    static func listingScript(for root: RemotePath) -> String {
        let inner = "printf \"%s\\t\" \"$(stat -c '%s|%Y|%F' -- \"$1\")\"; printf \"%s\\0\" \"$1\""
            .replacingOccurrences(of: "'", with: "'\\''")
        return "find \(ShellQuoting.quote(root)) -type f -exec sh -c '"
            + inner
            + "' sh {} +"
    }

    static func scoped(_ serial: String, _ rest: [String]) -> [String] {
        ["-s", serial] + rest
    }
}

/// One file record from the NUL-delimited listing.
public struct RemoteFileRecord: Equatable, Sendable {
    public let path: RemotePath
    public let sizeBytes: Int64
    public let modifiedEpochSeconds: Int64
    public let isRegularFile: Bool

    public init(path: RemotePath, sizeBytes: Int64, modifiedEpochSeconds: Int64, isRegularFile: Bool) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.modifiedEpochSeconds = modifiedEpochSeconds
        self.isRegularFile = isRegularFile
    }
}

public enum RemoteListingParser {
    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case malformedRecord(String)
        case pathOutsideRoot(root: String, path: String)
        case truncatedListing

        public var description: String {
            switch self {
            case .malformedRecord(let r): return "malformed remote listing record: \(r)"
            case .pathOutsideRoot(let root, let path): return "listed path \(path) is outside root \(root)"
            case .truncatedListing: return "remote listing ended without a final NUL terminator"
            }
        }
    }

    /// Parse the NUL-delimited output of listFiles. Records are strict: any
    /// malformed or out-of-root record fails the whole listing rather than
    /// being dropped — a partial listing must never be treated as
    /// authoritative (that would fabricate remote deletions).
    public static func parse(_ data: Data, root: RemotePath) throws -> [RemoteFileRecord] {
        var records: [RemoteFileRecord] = []
        var start = data.startIndex

        while start < data.endIndex {
            guard let nul = data[start...].firstIndex(of: 0) else {
                throw ParseError.truncatedListing
            }
            let record = data[start..<nul]
            start = data.index(after: nul)
            guard let line = String(data: record, encoding: .utf8) else {
                throw ParseError.malformedRecord("<non-utf8 record>")
            }
            guard let tab = line.firstIndex(of: "\t") else {
                throw ParseError.malformedRecord(line)
            }
            let meta = String(line[..<tab])
            let pathPart = String(line[line.index(after: tab)...])
            let fields = meta.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let size = Int64(fields[0]),
                  let mtime = Int64(fields[1]) else {
                throw ParseError.malformedRecord(line)
            }
            let kind = String(fields[2])
            guard let path = try? RemotePath(pathPart) else {
                throw ParseError.malformedRecord(line)
            }
            guard path.isWithin(root) else {
                throw ParseError.pathOutsideRoot(root: root.raw, path: path.raw)
            }
            records.append(RemoteFileRecord(
                path: path,
                sizeBytes: size,
                modifiedEpochSeconds: mtime,
                isRegularFile: kind.contains("regular file")
            ))
        }
        return records.filter(\.isRegularFile)
    }
}
