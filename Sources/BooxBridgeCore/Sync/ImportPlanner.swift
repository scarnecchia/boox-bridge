// pattern: Functional Core

import Foundation

public struct ImportPlan: Equatable, Sendable {
    public enum PullReason: Equatable, Sendable {
        case newFile
        case changedMetadata
    }

    public struct Pull: Equatable, Sendable {
        public let record: RemoteFileRecord
        public let reason: PullReason
    }

    public struct UnsupportedItem: Equatable, Sendable {
        public let relativePath: String
        public let extensionName: String
        public let explainable: Bool // known Boox format we can name
    }

    public let pulls: [Pull]
    public let unchangedCount: Int
    public let unsupported: [UnsupportedItem]
}

public enum ImportPlanner {
    /// Catalog keys snapshots by the path relative to the import root; the
    /// same derivation must produce both keys and lookups.
    public static func relativePath(of path: RemotePath, root: RemotePath) -> String {
        guard path.isWithin(root), path != root else { return path.raw }
        let dropped = path.raw.dropFirst(root.raw.count)
        return dropped.hasPrefix("/") ? String(dropped.dropFirst()) : String(dropped)
    }

    public static func plan(
        listing: [RemoteFileRecord],
        snapshots: [String: ImportSnapshot],
        root: RemotePath
    ) -> ImportPlan {
        var pulls: [ImportPlan.Pull] = []
        var unchanged = 0
        var unsupported: [ImportPlan.UnsupportedItem] = []

        for record in listing {
            let relative = relativePath(of: record.path, root: root)
            let ext = (record.path.lastComponent as NSString).pathExtension.lowercased()
            guard DocumentLimits.supportedExtensions.contains(ext) else {
                unsupported.append(ImportPlan.UnsupportedItem(
                    relativePath: relative,
                    extensionName: ext,
                    explainable: DocumentSniffer.knownUnsupportedExtensions.contains(ext)
                ))
                continue
            }
            guard let snapshot = snapshots[relative] else {
                pulls.append(ImportPlan.Pull(record: record, reason: .newFile))
                continue
            }
            if snapshot.remoteSize == record.sizeBytes && snapshot.remoteMtime == record.modifiedEpochSeconds {
                unchanged += 1
            } else {
                pulls.append(ImportPlan.Pull(record: record, reason: .changedMetadata))
            }
        }
        return ImportPlan(pulls: pulls, unchangedCount: unchanged, unsupported: unsupported)
    }
}
