import Foundation

/// Orchestrates incremental collection across all three sources into the cache.
public final class Collector {
    let cache: UsageCache
    let home: String

    public init(cache: UsageCache, home: String = NSHomeDirectory()) {
        self.cache = cache
        self.home = home
    }

    public struct Stats: Sendable {
        public var files = 0
        public var changed = 0
        public var events = 0
    }

    /// Run a full incremental pass and persist everything atomically.
    @discardableResult
    public func collectAll(log: ((String) -> Void)? = nil) -> Stats {
        var events: [EventKey: Int] = [:]
        var states: [(key: String, mtime: Double, offset: Int64, lastRowid: Int64)] = []
        let emit: (UsageEvent) -> Void = { e in events[EventKey(e), default: 0] += 1 }

        var stats = Stats()
        merge(&stats, collectJSONL(tool: .claudeCode, root: home + "/.claude/projects",
                                   emit: emit, states: &states, log: log))
        merge(&stats, collectJSONL(tool: .codex, root: home + "/.codex/sessions",
                                   emit: emit, states: &states, log: log))
        merge(&stats, collectHermes(emit: emit, states: &states, log: log))

        stats.events = events.values.reduce(0, +)
        try? cache.applyBatch(events: events, states: states)
        try? cache.setMeta("last_collected", ISO8601DateFormatter().string(from: Date()))
        loadInstalled()
        return stats
    }

    private func merge(_ a: inout Stats, _ b: Stats) {
        a.files += b.files; a.changed += b.changed
    }

    // MARK: - JSONL sources (Claude Code, Codex)

    private func collectJSONL(tool: ToolKind, root: String,
                              emit: (UsageEvent) -> Void,
                              states: inout [(key: String, mtime: Double, offset: Int64, lastRowid: Int64)],
                              log: ((String) -> Void)?) -> Stats {
        var stats = Stats()
        for path in jsonlFiles(under: root) {
            stats.files += 1
            guard let (mtime, size) = attrs(path) else { continue }
            let st = cache.ingestState(path)
            if let st, st.mtime == mtime, st.offset == size { continue }   // unchanged since last run

            let chunk = JSONL.newLines(path: path, fromOffset: st?.offset ?? 0, fileSize: size)
            if chunk.lines.isEmpty {
                // Touched but no new complete lines — still record mtime to skip next time.
                states.append((path, mtime, chunk.newOffset, 0))
                continue
            }
            stats.changed += 1
            switch tool {
            case .claudeCode:
                for line in chunk.lines { for e in ClaudeParser.events(line: line) { emit(e) } }
            case .codex:
                let fday = CodexParser.fileDay(from: (path as NSString).lastPathComponent) ?? TimeUtil.today()
                for line in chunk.lines { for e in CodexParser.events(line: line, fileDay: fday) { emit(e) } }
            case .hermes:
                break
            }
            states.append((path, mtime, chunk.newOffset, 0))
        }
        log?("\(tool.display): \(stats.changed)/\(stats.files) files changed")
        return stats
    }

    // MARK: - Hermes (per-persona SQLite)

    private func collectHermes(emit: (UsageEvent) -> Void,
                               states: inout [(key: String, mtime: Double, offset: Int64, lastRowid: Int64)],
                               log: ((String) -> Void)?) -> Stats {
        var stats = Stats()
        let profilesDir = home + "/.hermes/profiles"
        guard let personas = try? FileManager.default.contentsOfDirectory(atPath: profilesDir) else { return stats }
        for persona in personas where !persona.hasPrefix(".") {
            let dbPath = profilesDir + "/" + persona + "/state.db"
            guard FileManager.default.fileExists(atPath: dbPath) else { continue }
            stats.files += 1
            let key = "hermes:" + dbPath
            let from = cache.ingestState(key)?.lastRowid ?? 0
            let newMax = HermesParser.collect(dbPath: dbPath, persona: persona, fromRowid: from, emit: emit)
            if newMax != from { stats.changed += 1 }
            let mtime = attrs(dbPath)?.mtime ?? 0
            states.append((key, mtime, 0, newMax))
        }
        log?("Hermes: \(stats.changed)/\(stats.files) persona DBs changed")
        return stats
    }

    private func loadInstalled() {
        try? cache.setInstalled(tool: .claudeCode, category: .mcp,   items: Installed.claudeMCP(home: home))
        try? cache.setInstalled(tool: .claudeCode, category: .skill, items: Installed.claudeSkills(home: home))
        try? cache.setInstalled(tool: .codex,      category: .mcp,   items: Installed.codexMCP(home: home))
        try? cache.setInstalled(tool: .hermes,     category: .skill, items: Installed.hermesSkills(home: home))
    }

    // MARK: - FS helpers

    private func jsonlFiles(under root: String) -> [String] {
        var out: [String] = []
        guard let en = FileManager.default.enumerator(atPath: root) else { return out }
        for case let rel as String in en where rel.hasSuffix(".jsonl") {
            out.append(root + "/" + rel)
        }
        return out
    }

    private func attrs(_ path: String) -> (mtime: Double, size: Int64)? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let m = (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let s = (a[.size] as? NSNumber)?.int64Value ?? 0
        return (m, s)
    }
}
