import Foundation

/// The aggregate cache (`usage.db`): daily usage buckets + installed universe +
/// incremental ingest bookkeeping. The UI only ever reads from here.
public final class UsageCache {
    let db: SQLiteDB
    public let path: String

    public init(path: String) throws {
        self.path = path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        self.db = try SQLiteDB(path: path)
        try migrate()
    }

    private func migrate() throws {
        try db.runScript("""
        PRAGMA journal_mode=WAL;
        CREATE TABLE IF NOT EXISTS usage(
            tool TEXT NOT NULL,
            category TEXT NOT NULL,
            item TEXT NOT NULL,
            day TEXT NOT NULL,
            profile TEXT NOT NULL DEFAULT '',
            count INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(tool, category, item, day, profile)
        );
        CREATE INDEX IF NOT EXISTS idx_usage_day ON usage(day);
        CREATE INDEX IF NOT EXISTS idx_usage_cat ON usage(category, day);
        CREATE TABLE IF NOT EXISTS installed(
            tool TEXT NOT NULL, category TEXT NOT NULL, item TEXT NOT NULL,
            PRIMARY KEY(tool, category, item)
        );
        CREATE TABLE IF NOT EXISTS ingest_state(
            source_key TEXT PRIMARY KEY,
            mtime REAL NOT NULL DEFAULT 0,
            offset INTEGER NOT NULL DEFAULT 0,
            last_rowid INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
        """)
    }

    // MARK: - Ingest bookkeeping

    public struct IngestState { public var mtime: Double; public var offset: Int64; public var lastRowid: Int64 }

    public func ingestState(_ key: String) -> IngestState? {
        var result: IngestState?
        try? db.query("SELECT mtime, offset, last_rowid FROM ingest_state WHERE source_key=?",
                      bind: [.text(key)]) { r in
            result = IngestState(mtime: r.double(0), offset: r.int(1), lastRowid: r.int(2))
        }
        return result
    }

    public func setIngestState(_ key: String, mtime: Double, offset: Int64, lastRowid: Int64) throws {
        try db.run("""
        INSERT INTO ingest_state(source_key, mtime, offset, last_rowid) VALUES(?,?,?,?)
        ON CONFLICT(source_key) DO UPDATE SET mtime=excluded.mtime, offset=excluded.offset, last_rowid=excluded.last_rowid
        """, bind: [.text(key), .double(mtime), .int(offset), .int(lastRowid)])
    }

    // MARK: - Writing usage

    /// Fold a batch of new events into the daily buckets (additive — incremental safe).
    public func add(_ counts: [EventKey: Int]) throws {
        guard !counts.isEmpty else { return }
        try db.transaction {
            let st = try db.prepare("""
            INSERT INTO usage(tool, category, item, day, profile, count) VALUES(?,?,?,?,?,?)
            ON CONFLICT(tool, category, item, day, profile) DO UPDATE SET count = count + excluded.count
            """)
            defer { st.finalize() }
            for (k, n) in counts {
                st.bindAll([.text(k.tool.rawValue), .text(k.category.rawValue), .text(k.item),
                            .text(k.day), .text(k.profile), .int(Int64(n))])
                _ = st.step()
                sqlite3_reset_stmt(st)
            }
        }
    }

    /// Atomically persist a batch of new events together with the ingest-state
    /// advances that produced them. Doing both in one transaction guarantees we
    /// never advance an offset without having counted its events (no double-count
    /// on a mid-run crash, no lost events).
    public func applyBatch(events: [EventKey: Int],
                           states: [(key: String, mtime: Double, offset: Int64, lastRowid: Int64)]) throws {
        try db.transaction {
            if !events.isEmpty {
                let st = try db.prepare("""
                INSERT INTO usage(tool, category, item, day, profile, count) VALUES(?,?,?,?,?,?)
                ON CONFLICT(tool, category, item, day, profile) DO UPDATE SET count = count + excluded.count
                """)
                defer { st.finalize() }
                for (k, n) in events {
                    st.bindAll([.text(k.tool.rawValue), .text(k.category.rawValue), .text(k.item),
                                .text(k.day), .text(k.profile), .int(Int64(n))])
                    _ = st.step()
                    sqlite3_reset_stmt(st)
                }
            }
            if !states.isEmpty {
                let ss = try db.prepare("""
                INSERT INTO ingest_state(source_key, mtime, offset, last_rowid) VALUES(?,?,?,?)
                ON CONFLICT(source_key) DO UPDATE SET mtime=excluded.mtime, offset=excluded.offset, last_rowid=excluded.last_rowid
                """)
                defer { ss.finalize() }
                for s in states {
                    ss.bindAll([.text(s.key), .double(s.mtime), .int(s.offset), .int(s.lastRowid)])
                    _ = ss.step()
                    sqlite3_reset_stmt(ss)
                }
            }
        }
    }

    // MARK: - Installed universe

    public func setInstalled(tool: ToolKind, category: UsageCategory, items: [String]) throws {
        try db.transaction {
            for item in items where !item.isEmpty {
                try db.run("INSERT OR IGNORE INTO installed(tool, category, item) VALUES(?,?,?)",
                           bind: [.text(tool.rawValue), .text(category.rawValue), .text(item)])
            }
        }
    }

    public func installedItems(tool: ToolKind?, category: UsageCategory) -> [ToolKind: [String]] {
        var out: [ToolKind: [String]] = [:]
        var sql = "SELECT tool, item FROM installed WHERE category=?"
        var bind: [SQLValue] = [.text(category.rawValue)]
        if let tool { sql += " AND tool=?"; bind.append(.text(tool.rawValue)) }
        try? db.query(sql, bind: bind) { r in
            guard let t = ToolKind(rawValue: r.text(0) ?? ""), let item = r.text(1) else { return }
            out[t, default: []].append(item)
        }
        return out
    }

    // MARK: - Meta

    public func setMeta(_ key: String, _ value: String) throws {
        try db.run("INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                   bind: [.text(key), .text(value)])
    }
    public func meta(_ key: String) -> String? {
        var v: String?
        try? db.query("SELECT value FROM meta WHERE key=?", bind: [.text(key)]) { r in v = r.text(0) }
        return v
    }

    // MARK: - Queries for the UI

    private func toolClause(_ tool: ToolKind?, _ bind: inout [SQLValue]) -> String {
        guard let tool else { return "" }
        bind.append(.text(tool.rawValue))
        return " AND tool=?"
    }

    /// Top items by total count in the range.
    public func topItems(start: String, end: String, tool: ToolKind?, category: UsageCategory, limit: Int = 20) -> [ItemCount] {
        var bind: [SQLValue] = [.text(start), .text(end), .text(category.rawValue)]
        let tc = toolClause(tool, &bind)
        bind.append(.int(Int64(limit)))
        var out: [ItemCount] = []
        try? db.query("""
        SELECT tool, item, SUM(count) c, MAX(day) last
        FROM usage WHERE day BETWEEN ? AND ? AND category=?\(tc)
        GROUP BY tool, item ORDER BY c DESC LIMIT ?
        """, bind: bind) { r in
            guard let t = ToolKind(rawValue: r.text(0) ?? ""), let item = r.text(1) else { return }
            out.append(ItemCount(tool: t, item: item, count: Int(r.int(2)), lastUsed: r.text(3)))
        }
        return out
    }

    /// Per-day, per-tool totals for the time-series chart.
    public func dailyTrend(start: String, end: String, tool: ToolKind?, category: UsageCategory) -> [DayToolCount] {
        var bind: [SQLValue] = [.text(start), .text(end), .text(category.rawValue)]
        let tc = toolClause(tool, &bind)
        var out: [DayToolCount] = []
        try? db.query("""
        SELECT day, tool, SUM(count) c
        FROM usage WHERE day BETWEEN ? AND ? AND category=?\(tc)
        GROUP BY day, tool ORDER BY day
        """, bind: bind) { r in
            guard let t = ToolKind(rawValue: r.text(1) ?? "") else { return }
            out.append(DayToolCount(day: r.text(0) ?? "", tool: t, count: Int(r.int(2))))
        }
        return out
    }

    /// Total count per tool in the range (for the tool-comparison summary).
    public func totalsByTool(start: String, end: String, category: UsageCategory) -> [ToolKind: Int] {
        var out: [ToolKind: Int] = [:]
        try? db.query("""
        SELECT tool, SUM(count) c FROM usage
        WHERE day BETWEEN ? AND ? AND category=? GROUP BY tool
        """, bind: [.text(start), .text(end), .text(category.rawValue)]) { r in
            guard let t = ToolKind(rawValue: r.text(0) ?? "") else { return }
            out[t] = Int(r.int(1))
        }
        return out
    }

    public func grandTotal(start: String, end: String, category: UsageCategory, tool: ToolKind?) -> Int {
        var bind: [SQLValue] = [.text(start), .text(end), .text(category.rawValue)]
        let tc = toolClause(tool, &bind)
        var total = 0
        try? db.query("SELECT COALESCE(SUM(count),0) FROM usage WHERE day BETWEEN ? AND ? AND category=?\(tc)",
                      bind: bind) { r in total = Int(r.int(0)) }
        return total
    }
}

import SQLite3
// sqlite3_reset is named `sqlite3_reset` in the C API; expose a thin alias used above.
@inline(__always) func sqlite3_reset_stmt(_ s: Statement) { sqlite3_reset(s.stmt) }
