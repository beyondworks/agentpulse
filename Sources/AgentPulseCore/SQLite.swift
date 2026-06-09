import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal SQLite3 wrapper — zero external dependencies.
public final class SQLiteDB {
    var db: OpaquePointer?

    public init(path: String, readOnly: Bool = false) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown"
            sqlite3_close_v2(db)
            throw SQLiteError.message("open \(path): \(msg)")
        }
        sqlite3_busy_timeout(db, 5000)
    }

    deinit { sqlite3_close_v2(db) }

    private func fail(_ ctx: String) -> SQLiteError {
        .message("\(ctx): \(String(cString: sqlite3_errmsg(db)))")
    }

    /// Execute one or more SQL statements with no result rows.
    public func runScript(_ sql: String) throws {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK { throw fail("runScript") }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK { throw fail("prepare") }
        return Statement(stmt)
    }

    /// Run a query, invoking `row` for each result row.
    public func query(_ sql: String, bind: [SQLValue] = [], row: (Statement) -> Void) throws {
        let st = try prepare(sql)
        defer { st.finalize() }
        st.bindAll(bind)
        while st.step() { row(st) }
    }

    /// Run a single statement (insert/update) with bound parameters.
    public func run(_ sql: String, bind: [SQLValue] = []) throws {
        let st = try prepare(sql)
        defer { st.finalize() }
        st.bindAll(bind)
        _ = st.step()
    }

    public func transaction(_ body: () throws -> Void) throws {
        try runScript("BEGIN")
        do { try body(); try runScript("COMMIT") }
        catch { try? runScript("ROLLBACK"); throw error }
    }
}

public enum SQLiteError: Error, CustomStringConvertible {
    case message(String)
    public var description: String { if case .message(let m) = self { return m }; return "sqlite error" }
}

public enum SQLValue {
    case text(String)
    case int(Int64)
    case double(Double)
    case null
}

public final class Statement {
    let stmt: OpaquePointer?
    init(_ stmt: OpaquePointer?) { self.stmt = stmt }

    func bindAll(_ values: [SQLValue]) {
        for (i, v) in values.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s):   sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
            case .int(let n):    sqlite3_bind_int64(stmt, idx, n)
            case .double(let d): sqlite3_bind_double(stmt, idx, d)
            case .null:          sqlite3_bind_null(stmt, idx)
            }
        }
    }

    func step() -> Bool { sqlite3_step(stmt) == SQLITE_ROW }
    func finalize() { sqlite3_finalize(stmt) }

    public func text(_ col: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: c)
    }
    public func int(_ col: Int32) -> Int64 { sqlite3_column_int64(stmt, col) }
    public func double(_ col: Int32) -> Double { sqlite3_column_double(stmt, col) }
}
