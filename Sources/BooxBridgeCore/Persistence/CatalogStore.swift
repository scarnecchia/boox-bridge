// pattern: Imperative Shell
// Durable catalog: documents, revisions, page transcripts, OCR jobs, FTS5
// search, enrolled import roots, and library-only deletion. All writes are
// transactional; staging/blob moves happen outside and are committed via
// this store only after the file is validated.

import Foundation

public enum CatalogError: Error, Equatable, Sendable, CustomStringConvertible {
    case documentNotFound(Int64)
    case revisionNotFound(Int64)
    case pageNotFound(Int64)
    case ftsUnavailable(String)

    public var description: String {
        switch self {
        case .documentNotFound(let id): return "document \(id) not found in catalog"
        case .revisionNotFound(let id): return "revision \(id) not found in catalog"
        case .pageNotFound(let id): return "page \(id) not found in catalog"
        case .ftsUnavailable(let d): return "full-text search unavailable: \(d)"
        }
    }
}

public struct ImportSnapshot: Equatable, Sendable {
    public let revisionSHA256: String
    public let remoteSize: Int64
    public let remoteMtime: Int64
    public let kind: DocumentKind

    public init(revisionSHA256: String, remoteSize: Int64, remoteMtime: Int64, kind: DocumentKind) {
        self.revisionSHA256 = revisionSHA256
        self.remoteSize = remoteSize
        self.remoteMtime = remoteMtime
        self.kind = kind
    }
}

public enum ImportOutcome: Equatable, Sendable {
    case newDocument(documentID: Int64, revisionID: Int64)
    case newRevision(documentID: Int64, revisionID: Int64)
    case unchanged(documentID: Int64, revisionID: Int64)
}

public final class CatalogStore: @unchecked Sendable {
    private let db: SQLiteDatabase

    public init(database: SQLiteDatabase) throws {
        self.db = database
        try Self.migrate(db)
    }

    public static func open(atPath path: String) throws -> CatalogStore {
        try CatalogStore(database: SQLiteDatabase(path: path))
    }

    // MARK: - Migrations

    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE import_roots(
          id TEXT PRIMARY KEY,
          serial TEXT NOT NULL,
          remote_root TEXT NOT NULL,
          display_name TEXT NOT NULL,
          enrolled_at REAL NOT NULL
        );
        CREATE TABLE documents(
          id INTEGER PRIMARY KEY,
          serial TEXT NOT NULL,
          root_id TEXT NOT NULL,
          relative_path TEXT NOT NULL,
          title TEXT NOT NULL,
          folder TEXT NOT NULL DEFAULT '',
          kind TEXT NOT NULL,
          current_revision_id INTEGER REFERENCES revisions(id),
          created_at REAL NOT NULL,
          updated_at REAL NOT NULL,
          deleted_at REAL,
          UNIQUE(serial, root_id, relative_path)
        );
        CREATE TABLE revisions(
          id INTEGER PRIMARY KEY,
          document_id INTEGER NOT NULL REFERENCES documents(id),
          sha256 TEXT NOT NULL,
          size_bytes INTEGER NOT NULL,
          imported_at REAL NOT NULL,
          page_count INTEGER NOT NULL,
          remote_mtime INTEGER NOT NULL,
          remote_size INTEGER NOT NULL,
          UNIQUE(document_id, sha256)
        );
        CREATE TABLE pages(
          id INTEGER PRIMARY KEY,
          revision_id INTEGER NOT NULL REFERENCES revisions(id),
          page_index INTEGER NOT NULL,
          raw_text TEXT,
          effective_text TEXT,
          edited_at REAL,
          UNIQUE(revision_id, page_index)
        );
        CREATE TABLE ocr_jobs(
          id INTEGER PRIMARY KEY,
          revision_id INTEGER NOT NULL REFERENCES revisions(id),
          page_index INTEGER NOT NULL,
          profile_id TEXT NOT NULL,
          model_id TEXT NOT NULL,
          prompt_version INTEGER NOT NULL,
          state TEXT NOT NULL,
          attempts INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          run_at REAL,
          updated_at REAL NOT NULL,
          UNIQUE(revision_id, page_index, profile_id, model_id, prompt_version)
        );
        """,
    ]

    static func migrate(_ db: SQLiteDatabase) throws {
        let current = try db.userVersion()
        guard current < migrations.count else { return }
        for (offset, ddl) in migrations.enumerated() {
            let version = offset + 1
            guard current < version else { continue }
            try db.transaction {
                try db.execute(ddl)
                try db.execute("PRAGMA user_version=\(version)")
            }
        }
        try createFTS(db)
    }

    static func createFTS(_ db: SQLiteDatabase) throws {
        // A regular (self-contained) fts5 table, not contentless: contentless
        // tables forbid DELETE, and reindexing replaces rows on every edit.
        try db.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
          title, folder, body
        );
        """)
    }

    // MARK: - Import roots

    public func enrollRoot(_ root: ImportRoot) throws {
        try db.execute("""
        INSERT OR REPLACE INTO import_roots(id, serial, remote_root, display_name, enrolled_at)
        VALUES(?,?,?,?,?)
        """, bindings: [.text(root.id), .text(root.serial), .text(root.remoteRoot.raw),
                        .text(root.displayName), .real(root.enrolledAt.timeIntervalSince1970)])
    }

    public func removeRoot(id: String) throws {
        try db.execute("DELETE FROM import_roots WHERE id=?", bindings: [.text(id)])
    }

    public func listRoots() throws -> [ImportRoot] {
        let rows = try db.query("SELECT id, serial, remote_root, display_name, enrolled_at FROM import_roots ORDER BY enrolled_at")
        return rows.compactMap { row in
            guard case .text(let id) = row[0],
                  case .text(let serial) = row[1],
                  case .text(let rootRaw) = row[2],
                  case .text(let name) = row[3],
                  case .real(let enrolled) = row[4],
                  let root = try? RemotePath(rootRaw) else { return nil }
            return ImportRoot(id: id, serial: serial, remoteRoot: root, displayName: name,
                              enrolledAt: Date(timeIntervalSince1970: enrolled))
        }
    }

    // MARK: - Import planning support

    public func snapshots(forSerial serial: String, rootID: String) throws -> [String: ImportSnapshot] {
        let rows = try db.query("""
        SELECT d.relative_path, r.sha256, r.remote_size, r.remote_mtime, d.kind
        FROM documents d JOIN revisions r ON r.id = d.current_revision_id
        WHERE d.serial = ? AND d.root_id = ? AND d.deleted_at IS NULL
        """, bindings: [.text(serial), .text(rootID)])
        var result: [String: ImportSnapshot] = [:]
        for row in rows {
            guard case .text(let path) = row[0],
                  case .text(let sha) = row[1],
                  case .integer(let size) = row[2],
                  case .integer(let mtime) = row[3],
                  case .text(let kindRaw) = row[4] else { continue }
            result[path] = ImportSnapshot(
                revisionSHA256: sha, remoteSize: size, remoteMtime: mtime,
                kind: DocumentKind(rawValue: kindRaw) ?? .unsupported
            )
        }
        return result
    }

    /// Commit a validated import. Idempotent per (document, content hash):
    /// re-importing identical content is a no-op that returns `.unchanged`.
    public func commitImport(
        key: DocumentKey,
        kind: DocumentKind,
        contentSHA256: String,
        sizeBytes: Int64,
        pageCount: Int,
        remoteMtime: Int64,
        remoteSize: Int64,
        at date: Date,
        title: String? = nil
    ) throws -> ImportOutcome {
        try db.transaction {
            let existing = try db.query(
                "SELECT id FROM documents WHERE serial=? AND root_id=? AND relative_path=? AND deleted_at IS NULL",
                bindings: [.text(key.serial), .text(key.rootID), .text(key.relativePath)]
            )
            let documentID: Int64
            if case .integer(let id) = existing.first?.first {
                documentID = id
                // Content already recorded for this document → no-op.
                let dupe = try db.query(
                    "SELECT id FROM revisions WHERE document_id=? AND sha256=?",
                    bindings: [.integer(documentID), .text(contentSHA256)]
                )
                if case .integer(let revisionID) = dupe.first?.first {
                    return .unchanged(documentID: documentID, revisionID: revisionID)
                }
            } else {
                let resolvedTitle = title ?? URL(fileURLWithPath: key.relativePath).lastPathComponent
                try db.execute("""
                INSERT INTO documents(serial, root_id, relative_path, title, folder, kind, current_revision_id,
                                      created_at, updated_at, deleted_at)
                VALUES(?,?,?,?,?,?,NULL,?,?,NULL)
                """, bindings: [.text(key.serial), .text(key.rootID), .text(key.relativePath),
                                .text(resolvedTitle), .text(""), .text(kind.rawValue),
                                .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970)])
                documentID = db.lastInsertRowID()
            }

            try db.execute("""
            INSERT INTO revisions(document_id, sha256, size_bytes, imported_at, page_count, remote_mtime, remote_size)
            VALUES(?,?,?,?,?,?,?)
            """, bindings: [.integer(documentID), .text(contentSHA256), .integer(sizeBytes),
                            .real(date.timeIntervalSince1970), .integer(Int64(pageCount)),
                            .integer(remoteMtime), .integer(remoteSize)])
            let revisionID = db.lastInsertRowID()

            for pageIndex in 0..<max(pageCount, 0) {
                try db.execute(
                    "INSERT INTO pages(revision_id, page_index) VALUES(?,?)",
                    bindings: [.integer(revisionID), .integer(Int64(pageIndex))]
                )
            }

            let wasFirstRevision: Bool
            let prior = try db.query("SELECT current_revision_id FROM documents WHERE id=?", bindings: [.integer(documentID)])
            if case .null = prior.first?.first { wasFirstRevision = true } else { wasFirstRevision = false }

            try db.execute("UPDATE documents SET current_revision_id=?, updated_at=? WHERE id=?",
                           bindings: [.integer(revisionID), .real(date.timeIntervalSince1970), .integer(documentID)])
            try refreshFTS(documentID: documentID)

            if wasFirstRevision {
                return .newDocument(documentID: documentID, revisionID: revisionID)
            }
            return .newRevision(documentID: documentID, revisionID: revisionID)
        }
    }

    // MARK: - Reading

    public func listDocuments(includeDeleted: Bool = false) throws -> [DocumentSummary] {
        let filter = includeDeleted ? "" : "WHERE d.deleted_at IS NULL"
        let rows = try db.query("""
        SELECT d.id, d.serial, d.root_id, d.relative_path, d.title, d.folder, d.kind,
               COALESCE(d.current_revision_id, 0),
               (SELECT COUNT(*) FROM revisions r2 WHERE r2.document_id = d.id),
               COALESCE((SELECT r.page_count FROM revisions r WHERE r.id = d.current_revision_id), 0),
               d.created_at, d.updated_at
        FROM documents d \(filter) ORDER BY d.updated_at DESC
        """)
        return rows.compactMap(Self.summary(from:))
    }

    public func document(id: Int64) throws -> DocumentSummary? {
        let rows = try db.query("""
        SELECT d.id, d.serial, d.root_id, d.relative_path, d.title, d.folder, d.kind,
               COALESCE(d.current_revision_id, 0),
               (SELECT COUNT(*) FROM revisions r2 WHERE r2.document_id = d.id),
               COALESCE((SELECT r.page_count FROM revisions r WHERE r.id = d.current_revision_id), 0),
               d.created_at, d.updated_at
        FROM documents d WHERE d.id=?
        """, bindings: [.integer(id)])
        return rows.first.flatMap(Self.summary(from:))
    }

    public func revisions(documentID: Int64) throws -> [RevisionRecord] {
        let rows = try db.query("""
        SELECT id, document_id, sha256, size_bytes, imported_at, page_count, remote_mtime, remote_size
        FROM revisions WHERE document_id=? ORDER BY id
        """, bindings: [.integer(documentID)])
        return rows.compactMap { row in
            guard case .integer(let id) = row[0], case .integer(let doc) = row[1],
                  case .text(let sha) = row[2], case .integer(let size) = row[3],
                  case .real(let imported) = row[4], case .integer(let pages) = row[5],
                  case .integer(let mtime) = row[6], case .integer(let rsize) = row[7] else { return nil }
            return RevisionRecord(id: id, documentID: doc, contentSHA256: sha, sizeBytes: size,
                                  importedAt: Date(timeIntervalSince1970: imported), pageCount: Int(pages),
                                  remoteMtime: mtime, remoteSize: rsize)
        }
    }

    public func pages(revisionID: Int64) throws -> [PageTranscript] {
        let rows = try db.query("""
        SELECT id, revision_id, page_index, raw_text, effective_text, edited_at
        FROM pages WHERE revision_id=? ORDER BY page_index
        """, bindings: [.integer(revisionID)])
        return rows.compactMap { row in
            guard case .integer(let id) = row[0], case .integer(let rev) = row[1],
                  case .integer(let index) = row[2] else { return nil }
            let raw = Self.string(row[3]) ?? ""
            let effective = Self.string(row[4]) ?? ""
            let edited: Date? = Self.real(row[5]).map(Date.init(timeIntervalSince1970:))
            return PageTranscript(id: id, revisionID: rev, pageIndex: Int(index),
                                  rawTranscription: raw, effectiveText: effective, lastEditedAt: edited)
        }
    }

    public func revisionContentSHA256(revisionID: Int64) throws -> String? {
        let rows = try db.query("SELECT sha256 FROM revisions WHERE id=?", bindings: [.integer(revisionID)])
        return Self.string(rows.first?.first ?? .null)
    }

    // MARK: - Editing (user transcripts)

    /// Edit the effective text of a page. User edits are never overwritten
    /// by OCR: raw transcription is stored separately.
    public func updateEffectiveText(pageID: Int64, text: String, at date: Date) throws {
        try db.transaction {
            let rows = try db.query("SELECT revision_id FROM pages WHERE id=?", bindings: [.integer(pageID)])
            guard case .integer(let revisionID) = rows.first?.first else { throw CatalogError.pageNotFound(pageID) }
            try db.execute("UPDATE pages SET effective_text=?, edited_at=? WHERE id=?",
                           bindings: [.text(text), .real(date.timeIntervalSince1970), .integer(pageID)])
            let doc = try db.query("SELECT document_id FROM revisions WHERE id=?", bindings: [.integer(revisionID)])
            if case .integer(let documentID) = doc.first?.first {
                try refreshFTS(documentID: documentID)
            }
        }
    }

    /// Record OCR output. The effective text is only filled in when the user
    /// has never edited the page (edited_at IS NULL).
    public func recordTranscription(revisionID: Int64, pageIndex: Int, rawText: String, at date: Date) throws {
        try db.transaction {
            let rows = try db.query(
                "SELECT id, edited_at FROM pages WHERE revision_id=? AND page_index=?",
                bindings: [.integer(revisionID), .integer(Int64(pageIndex))]
            )
            guard case .integer(let pageID) = rows.first?.first else { throw CatalogError.revisionNotFound(revisionID) }
            let neverEdited: Bool
            if case .null = rows.first?[1] { neverEdited = true } else { neverEdited = false }
            if neverEdited {
                try db.execute("UPDATE pages SET raw_text=?, effective_text=? WHERE id=?",
                               bindings: [.text(rawText), .text(rawText), .integer(pageID)])
            } else {
                try db.execute("UPDATE pages SET raw_text=? WHERE id=?",
                               bindings: [.text(rawText), .integer(pageID)])
            }
            let doc = try db.query("SELECT document_id FROM revisions WHERE id=?", bindings: [.integer(revisionID)])
            if case .integer(let documentID) = doc.first?.first {
                try refreshFTS(documentID: documentID)
            }
        }
    }

    // MARK: - Local (library-only) deletion

    /// Mark a document deleted in the local library. Never touches the
    /// device, blobs, or revisions — re-import restores visibility.
    public func markDocumentDeleted(_ documentID: Int64, at date: Date) throws {
        try db.execute("UPDATE documents SET deleted_at=?, updated_at=? WHERE id=?",
                       bindings: [.real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970), .integer(documentID)])
        try db.execute("DELETE FROM notes_fts WHERE rowid=?", bindings: [.integer(documentID)])
    }

    // MARK: - OCR queue

    /// Enqueue a job unless an active (queued/running) job with the same
    /// identity exists. Returns the job id, or nil when deduplicated.
    @discardableResult
    public func enqueueJob(
        revisionID: Int64, pageIndex: Int, profileID: String, modelID: String,
        promptVersion: Int, at date: Date
    ) throws -> Int64? {
        try db.transaction {
            let active = try db.query("""
            SELECT id FROM ocr_jobs
            WHERE revision_id=? AND page_index=? AND profile_id=? AND model_id=? AND prompt_version=?
              AND state IN ('queued','running')
            """, bindings: [.integer(revisionID), .integer(Int64(pageIndex)), .text(profileID),
                            .text(modelID), .integer(Int64(promptVersion))])
            if case .integer(let existing) = active.first?.first { _ = existing; return nil }

            try db.execute("""
            INSERT INTO ocr_jobs(revision_id, page_index, profile_id, model_id, prompt_version,
                                 state, attempts, updated_at)
            VALUES(?,?,?,?,?,'queued',0,?)
            """, bindings: [.integer(revisionID), .integer(Int64(pageIndex)), .text(profileID),
                            .text(modelID), .integer(Int64(promptVersion)),
                            .real(date.timeIntervalSince1970)])
            return db.lastInsertRowID()
        }
    }

    public func job(id: Int64) throws -> OcrJob? {
        let rows = try db.query("""
        SELECT id, revision_id, page_index, profile_id, model_id, prompt_version, state, attempts, last_error, run_at
        FROM ocr_jobs WHERE id=?
        """, bindings: [.integer(id)])
        return rows.first.flatMap(Self.job(from:))
    }

    public func jobs(revisionID: Int64) throws -> [OcrJob] {
        let rows = try db.query("""
        SELECT id, revision_id, page_index, profile_id, model_id, prompt_version, state, attempts, last_error, run_at
        FROM ocr_jobs WHERE revision_id=? ORDER BY id
        """, bindings: [.integer(revisionID)])
        return rows.compactMap(Self.job(from:))
    }

    public func activeJobs() throws -> [OcrJob] {
        let rows = try db.query("""
        SELECT id, revision_id, page_index, profile_id, model_id, prompt_version, state, attempts, last_error, run_at
        FROM ocr_jobs WHERE state IN ('queued','running') ORDER BY id
        """)
        return rows.compactMap(Self.job(from:))
    }

    /// Oldest queued job, for the single-concurrency runner.
    public func nextQueuedJob() throws -> OcrJob? {
        let rows = try db.query("""
        SELECT id, revision_id, page_index, profile_id, model_id, prompt_version, state, attempts, last_error, run_at
        FROM ocr_jobs WHERE state='queued' ORDER BY id LIMIT 1
        """)
        return rows.first.flatMap(Self.job(from:))
    }

    public func updateJob(id: Int64, state: OcrRunState, attempts: Int, lastError: String?, at date: Date) throws {
        try db.execute("""
        UPDATE ocr_jobs SET state=?, attempts=?, last_error=?, run_at=?, updated_at=?
        WHERE id=?
        """, bindings: [.text(state.rawValue), .integer(Int64(attempts)),
                        lastError.map { .text($0) } ?? .null,
                        .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970),
                        .integer(id)])
    }

    /// Interrupted-running recovery at launch: never silently restart paid
    /// work; surface interrupted jobs as failed-for-now with a resumable
    /// state the user can retry explicitly.
    public func recoverInterruptedJobs(at date: Date) throws -> Int {
        try db.execute("""
        UPDATE ocr_jobs SET state='failed', last_error='interrupted by app restart', updated_at=?
        WHERE state='running'
        """, bindings: [.real(date.timeIntervalSince1970)])
        return db.changes()
    }

    /// The current revision of a document — used to check a late OCR result
    /// against the revision it was produced for.
    public func currentRevisionID(documentID: Int64) throws -> Int64? {
        let rows = try db.query("SELECT current_revision_id FROM documents WHERE id=?", bindings: [.integer(documentID)])
        switch rows.first?.first {
        case .integer(let id): return id
        default: return nil
        }
    }

    public func documentID(revisionID: Int64) throws -> Int64? {
        let rows = try db.query("SELECT document_id FROM revisions WHERE id=?", bindings: [.integer(revisionID)])
        switch rows.first?.first {
        case .integer(let id): return id
        default: return nil
        }
    }

    // MARK: - FTS

    /// Reindex one document from its current revision's effective text.
    /// Called inside transactions after any text/metadata change.
    func refreshFTS(documentID: Int64) throws {
        let rows = try db.query("""
        SELECT d.title, d.folder,
               COALESCE((SELECT group_concat(COALESCE(p.effective_text,''), char(10))
                         FROM pages p JOIN revisions r ON r.id = p.revision_id
                         WHERE r.id = d.current_revision_id ORDER BY p.page_index), '')
        FROM documents d WHERE d.id=? AND d.deleted_at IS NULL
        """, bindings: [.integer(documentID)])
        guard let row = rows.first,
              case .text(let title) = row[0],
              case .text(let folder) = row[1],
              case .text(let body) = row[2] else { return }
        try db.execute("DELETE FROM notes_fts WHERE rowid=?", bindings: [.integer(documentID)])
        try db.execute("INSERT INTO notes_fts(rowid, title, folder, body) VALUES(?,?,?,?)",
                       bindings: [.integer(documentID), .text(title), .text(folder), .text(body)])
    }

    public struct SearchHit: Equatable, Sendable {
        public let documentID: Int64
        public let title: String
        public let snippet: String
    }

    public func search(matching phrase: String, limit: Int = 50) throws -> [SearchHit] {
        let escaped = FTSQuery.phrase(phrase)
        let rows = try db.query("""
        SELECT rowid, title, snippet(notes_fts, 2, '«', '»', '…', 24)
        FROM notes_fts WHERE notes_fts MATCH ? ORDER BY rank LIMIT ?
        """, bindings: [.text(escaped), .integer(Int64(limit))])
        return rows.compactMap { row in
            guard case .integer(let id) = row[0],
                  case .text(let title) = row[1],
                  case .text(let snippet) = row[2] else { return nil }
            return SearchHit(documentID: id, title: title, snippet: snippet)
        }
    }

    // MARK: - Row mapping

    static func summary(from row: [SQLiteValue]) -> DocumentSummary? {
        guard case .integer(let id) = row[0],
              case .text(let serial) = row[1],
              case .text(let rootID) = row[2],
              case .text(let rel) = row[3],
              case .text(let title) = row[4],
              case .text(let folder) = row[5],
              case .text(let kindRaw) = row[6],
              case .integer(let revisionID) = row[7],
              case .integer(let revisionCount) = row[8],
              case .integer(let pageCount) = row[9],
              case .real(let created) = row[10],
              case .real(let updated) = row[11] else { return nil }
        return DocumentSummary(
            id: id,
            key: DocumentKey(serial: serial, rootID: rootID, relativePath: rel),
            title: title, folder: folder,
            kind: DocumentKind(rawValue: kindRaw) ?? .unsupported,
            currentPageRevisionID: revisionID,
            revisionCount: Int(revisionCount),
            pageCount: Int(pageCount),
            importedAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    static func job(from row: [SQLiteValue]) -> OcrJob? {
        guard case .integer(let id) = row[0],
              case .integer(let revisionID) = row[1],
              case .integer(let pageIndex) = row[2],
              case .text(let profileID) = row[3],
              case .text(let modelID) = row[4],
              case .integer(let promptVersion) = row[5],
              case .text(let stateRaw) = row[6],
              case .integer(let attempts) = row[7] else { return nil }
        return OcrJob(
            id: id, revisionID: revisionID, pageIndex: Int(pageIndex),
            profileID: profileID, modelID: modelID, promptVersion: Int(promptVersion),
            state: OcrRunState(rawValue: stateRaw) ?? .failed,
            attempts: Int(attempts),
            lastError: string(row[8]),
            runAt: real(row[9]).map(Date.init(timeIntervalSince1970:))
        )
    }

    static func string(_ value: SQLiteValue) -> String? {
        if case .text(let s) = value { return s }
        return nil
    }

    static func real(_ value: SQLiteValue) -> Double? {
        switch value {
        case .real(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
}

// MARK: - FTS input safety

/// pattern: Functional Core
/// Literal user input must never be executed as FTS syntax. Everything is
/// treated as one quoted phrase with doubled internal quotes; operators and
/// column filters in user input lose their special meaning.
public enum FTSQuery {
    public static func phrase(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "\"\"" }
        let escaped = trimmed.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
