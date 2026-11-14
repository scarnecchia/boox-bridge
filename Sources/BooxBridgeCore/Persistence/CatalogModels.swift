// pattern: Functional Core (type-only declarations plus plain initializers)

import Foundation

/// How a document is identified across imports: the device serial, the
/// enrolled import root, and the path relative to that root. Content hashes
/// are revision identity, NOT document identity — a remote rename looks
/// like a new document under this model, deliberately.
public struct DocumentKey: Equatable, Hashable, Sendable {
    public let serial: String
    public let rootID: String
    public let relativePath: String

    public init(serial: String, rootID: String, relativePath: String) {
        self.serial = serial
        self.rootID = rootID
        self.relativePath = relativePath
    }
}

public enum DocumentKind: String, Equatable, Sendable {
    case pdf
    case png
    case jpeg
    case unsupported
}

public struct DocumentSummary: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let key: DocumentKey
    public var title: String
    public var folder: String
    public let kind: DocumentKind
    public let currentPageRevisionID: Int64
    public let revisionCount: Int
    public let pageCount: Int
    public let importedAt: Date
    public let updatedAt: Date

    public init(id: Int64, key: DocumentKey, title: String, folder: String, kind: DocumentKind,
                currentPageRevisionID: Int64, revisionCount: Int, pageCount: Int,
                importedAt: Date, updatedAt: Date) {
        self.id = id
        self.key = key
        self.title = title
        self.folder = folder
        self.kind = kind
        self.currentPageRevisionID = currentPageRevisionID
        self.revisionCount = revisionCount
        self.pageCount = pageCount
        self.importedAt = importedAt
        self.updatedAt = updatedAt
    }
}

public struct RevisionRecord: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let documentID: Int64
    public let contentSHA256: String
    public let sizeBytes: Int64
    public let importedAt: Date
    public let pageCount: Int
    /// Original device-side metadata captured at import.
    public let remoteMtime: Int64
    public let remoteSize: Int64

    public init(id: Int64, documentID: Int64, contentSHA256: String, sizeBytes: Int64,
                importedAt: Date, pageCount: Int, remoteMtime: Int64, remoteSize: Int64) {
        self.id = id
        self.documentID = documentID
        self.contentSHA256 = contentSHA256
        self.sizeBytes = sizeBytes
        self.importedAt = importedAt
        self.pageCount = pageCount
        self.remoteMtime = remoteMtime
        self.remoteSize = remoteSize
    }
}

public struct PageTranscript: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let revisionID: Int64
    public let pageIndex: Int
    /// Raw OCR output, immutable once written.
    public var rawTranscription: String
    /// User-editable effective text; edits never get overwritten by OCR.
    public var effectiveText: String
    public let lastEditedAt: Date?

    public init(id: Int64, revisionID: Int64, pageIndex: Int, rawTranscription: String,
                effectiveText: String, lastEditedAt: Date?) {
        self.id = id
        self.revisionID = revisionID
        self.pageIndex = pageIndex
        self.rawTranscription = rawTranscription
        self.effectiveText = effectiveText
        self.lastEditedAt = lastEditedAt
    }
}

public enum OcrRunState: String, Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
}

public struct OcrJob: Equatable, Sendable, Identifiable {
    public let id: Int64
    public let revisionID: Int64
    public let pageIndex: Int
    public let profileID: String
    public let modelID: String
    public let promptVersion: Int
    public var state: OcrRunState
    public var attempts: Int
    public var lastError: String?
    public var runAt: Date?

    public init(id: Int64, revisionID: Int64, pageIndex: Int, profileID: String, modelID: String,
                promptVersion: Int, state: OcrRunState, attempts: Int, lastError: String? = nil, runAt: Date? = nil) {
        self.id = id
        self.revisionID = revisionID
        self.pageIndex = pageIndex
        self.profileID = profileID
        self.modelID = modelID
        self.promptVersion = promptVersion
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
        self.runAt = runAt
    }

    /// Queue identity: a repeat enqueue of the same tuple is a no-op.
    public var identity: OcrJobIdentity {
        OcrJobIdentity(revisionID: revisionID, pageIndex: pageIndex, profileID: profileID,
                       modelID: modelID, promptVersion: promptVersion)
    }
}

public struct OcrJobIdentity: Equatable, Hashable, Sendable {
    public let revisionID: Int64
    public let pageIndex: Int
    public let profileID: String
    public let modelID: String
    public let promptVersion: Int

    public init(revisionID: Int64, pageIndex: Int, profileID: String, modelID: String, promptVersion: Int) {
        self.revisionID = revisionID
        self.pageIndex = pageIndex
        self.profileID = profileID
        self.modelID = modelID
        self.promptVersion = promptVersion
    }
}

/// An enrolled import root: a device serial plus a shared-storage folder the
/// user explicitly chose for incremental device→Mac copying.
public struct ImportRoot: Equatable, Sendable, Identifiable {
    public let id: String
    public let serial: String
    public let remoteRoot: RemotePath
    public let displayName: String
    public let enrolledAt: Date

    public init(id: String, serial: String, remoteRoot: RemotePath, displayName: String, enrolledAt: Date) {
        self.id = id
        self.serial = serial
        self.remoteRoot = remoteRoot
        self.displayName = displayName
        self.enrolledAt = enrolledAt
    }
}
