
// pattern: Imperative Shell

import CBooxSQLite
import Foundation

public enum SQLiteValue: Sendable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

public enum SQLiteError: Error, Equatable, Sendable, CustomStringConvertible {
    case openFailed(path: String, detail: String)
    case prepareFailed(sql: String, detail: String)
    case stepFailed(sql: String, detail: String)
    case bindFailed(sql: String, index: Int, detail: String)
    case execFailed(sql: String, detail: String)

    public var description: String {
        switch self {
        case .openFailed(let p, let d): return "failed to open database at \(p): \(d)"
        case .prepareFailed(let s, let d): return "failed to prepare '\(s.prefix(120))': \(d)"
        case .stepFailed(let s, let d): return "failed to step '\(s.prefix(120))': \(d)"
        case .bindFailed(let s, let i, let d): return "failed to bind parameter \(i) of '\(s.prefix(120))': \(d)"
        case .execFailed(let s, let d): return "failed to execute '\(s.prefix(120))': \(d)"
        }
    }
}

public final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    // Recursive: transaction bodies call back into execute/query on the
    // same instance while the transaction holds the lock.
    private let lock = NSRecursiveLock()

    public init(path: String) throws {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite error \(rc)"
            if handle != nil { sqlite3_close(handle) }
            throw SQLiteError.openFailed(path: path, detail: detail)
        }
        self.db = handle
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=5000")
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    public static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    /// User-version used for schema migrations.
    public func userVersion() throws -> Int {
        let rows = try query("PRAGMA user_version", bindings: [])
        guard let first = rows.first?.first, case .integer(let v) = first else { return 0 }
        return Int(v)
    }

    public func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version=\(version)")
    }

    /// Run a statement with no result rows (DDL, INSERT, PRAGMA).
    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        _ = try run(sql, bindings: bindings, collectingRows: false)
    }

    /// Run a SELECT and collect all rows.
    public func query(_ sql: String, bindings: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        try run(sql, bindings: bindings, collectingRows: true)
    }

    public func lastInsertRowID() -> Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return -1 }
        return sqlite3_last_insert_rowid(db)
    }

    public func changes() -> Int {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// Serialized transaction: BEGIN IMMEDIATE … COMMIT, ROLLBACK on throw.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.execFailed(sql: "<closed>", detail: "database closed") }
        var rc = sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        guard rc == SQLITE_OK else {
            throw SQLiteError.execFailed(sql: "BEGIN", detail: String(cString: sqlite3_errmsg(db)))
        }
        do {
            let result = try body()
            rc = sqlite3_exec(db, "COMMIT", nil, nil, nil)
            guard rc == SQLITE_OK else {
                throw SQLiteError.execFailed(sql: "COMMIT", detail: String(cString: sqlite3_errmsg(db)))
            }
            return result
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func run(_ sql: String, bindings: [SQLiteValue], collectingRows: Bool) throws -> [[SQLiteValue]] {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.execFailed(sql: sql, detail: "database closed") }

        // sqlite3_prepare_v2 prepares only the FIRST statement of a
        // multi-statement string; walk the tail so schema DDL batches run
        // completely. Bindings apply to the first statement only (callers
        // never bind multi-statement SQL).
        var remaining = sql
        var firstStatement = true
        var rows: [[SQLiteValue]] = []

        while !remaining.isEmpty {
            let outcome = try Self.runOneStatement(
                db: db, sql: remaining,
                bindings: firstStatement ? bindings : [],
                collectingRows: collectingRows
            )
            rows.append(contentsOf: outcome.rows)
            firstStatement = false
            guard let tailText = outcome.remainingTail,
                  !tailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
            remaining = tailText
        }
        return rows
    }

    private struct StatementOutcome {
        let rows: [[SQLiteValue]]
        let remainingTail: String?
    }

    private static func runOneStatement(
        db: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue],
        collectingRows: Bool
    ) throws -> StatementOutcome {
        // pzTail points INTO the zSql buffer; the buffer must outlive the
        // call, and the tail must be COPIED before the buffer goes away.
        // Swift's implicit String→C string conversion is only valid for the
        // call itself, so everything happens inside withCString.
        var outcome: StatementOutcome?
        try sql.withCString { csql in
            var statement: OpaquePointer?
            var tail: UnsafePointer<CChar>?
            guard sqlite3_prepare_v2(db, csql, -1, &statement, &tail) == SQLITE_OK else {
                throw SQLiteError.prepareFailed(sql: sql, detail: String(cString: sqlite3_errmsg(db)))
            }
            guard let statement else {
                outcome = StatementOutcome(rows: [], remainingTail: nil)
                return
            }
            defer { sqlite3_finalize(statement) }

            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let rc: Int32
                switch value {
                case .integer(let n): rc = sqlite3_bind_int64(statement, index, n)
                case .real(let d): rc = sqlite3_bind_double(statement, index, d)
                case .text(let s): rc = sqlite3_bind_text(statement, index, s, -1, SQLITE_TRANSIENT)
                case .blob(let b):
                    rc = b.withUnsafeBytes { raw in
                        guard let base = raw.baseAddress else { return sqlite3_bind_zeroblob(statement, index, 0) }
                        return sqlite3_bind_blob(statement, index, base, Int32(raw.count), SQLITE_TRANSIENT)
                    }
                case .null: rc = sqlite3_bind_null(statement, index)
                }
                guard rc == SQLITE_OK else {
                    throw SQLiteError.bindFailed(sql: sql, index: Int(index), detail: String(cString: sqlite3_errmsg(db)))
                }
            }

            var rows: [[SQLiteValue]] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    if collectingRows {
                        let columnCount = Int(sqlite3_column_count(statement))
                        var row: [SQLiteValue] = []
                        row.reserveCapacity(columnCount)
                        for column in 0..<columnCount {
                            row.append(value(statement: statement, column: Int32(column)))
                        }
                        rows.append(row)
                    }
                } else if step == SQLITE_DONE {
                    break
                } else {
                    throw SQLiteError.stepFailed(sql: sql, detail: String(cString: sqlite3_errmsg(db)))
                }
            }
            outcome = StatementOutcome(rows: rows, remainingTail: tail.map { String(cString: $0) })
        }
        return outcome ?? StatementOutcome(rows: [], remainingTail: nil)
    }

    private static func value(statement: OpaquePointer, column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            if let cString = sqlite3_column_text(statement, column) {
                return .text(String(cString: cString))
            }
            return .text("")
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(statement, column) {
                let count = Int(sqlite3_column_bytes(statement, column))
                return .blob(Data(bytes: bytes, count: count))
            }
            return .blob(Data())
        default: return .null
        }
    }
}

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
