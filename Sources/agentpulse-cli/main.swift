import Foundation
import AgentPulseCore

// Headless collector + reporter — used to validate parsing against the raw logs
// before (and independently of) the GUI.
//   agentpulse-cli            collect, then print a 30-day report
//   agentpulse-cli --report   skip collection, just report from the cache

let home = NSHomeDirectory()
let cachePath = home + "/Library/Application Support/AgentPulse/usage.db"
let args = Set(CommandLine.arguments.dropFirst())

func err(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

// Verify the live plan-usage fetch (reads the OAuth token, calls oauth/usage).
if args.contains("--fetchplan") {
    err("Fetching live plan usage (may prompt once for Keychain access)…")
    if let pu = await LiveUsage.fetchPlanUsage() {
        print("LIVE  5h=\(pu.fiveHourPercent.map(String.init) ?? "-")%  weekly=\(pu.weeklyPercent.map(String.init) ?? "-")%  sonnet=\(pu.sonnetWeeklyPercent.map(String.init) ?? "-")%  (updated \(pu.updatedAt))")
    } else {
        print("LIVE  nil — no valid OAuth token (expired/none) or no subscription usage; UI falls back to cache.")
    }
    exit(0)
}

// Live-monitor verification: print plan usage + active session context.
if args.contains("--live") {
    if let pu = LiveUsage.planUsage() {
        let fresh = pu.isFresh() ? "fresh" : "STALE"
        print("=== Plan usage (\(pu.sourceFile), \(fresh), updated \(pu.updatedAt)) ===")
        print("  5-hour: \(pu.fiveHourPercent.map(String.init) ?? "—")%   weekly: \(pu.weeklyPercent.map(String.init) ?? "—")%   sonnet weekly: \(pu.sonnetWeeklyPercent.map(String.init) ?? "—")%")
        print("  resets: 5h=\(pu.fiveHourResetsAt.map { "\($0)" } ?? "—")  weekly=\(pu.weeklyResetsAt.map { "\($0)" } ?? "—")")
    } else {
        print("=== Plan usage: no cache (OMC not present, or API-key session) ===")
    }
    let sessions = LiveUsage.activeSessions(withinMinutes: 10)
    print("\n=== Active Claude Code sessions (last 10 min): \(sessions.count) ===")
    for s in sessions {
        let pct = String(format: "%5.1f%%", s.usedPercent)
        let proj = s.project.count >= 20 ? s.project : s.project + String(repeating: " ", count: 20 - s.project.count)
        print("  \(pct)  \(s.ctxTokens) / \(s.windowSize)  \(proj) \(s.model) \(s.shortId)")
    }
    exit(0)
}

do {
    let cache = try UsageCache(path: cachePath)

    if !args.contains("--report") {
        err("Collecting into \(cachePath) …")
        let t0 = Date()
        let stats = Collector(cache: cache).collectAll { err("  " + $0) }
        let dt = String(format: "%.1fs", Date().timeIntervalSince(t0))
        err("Done in \(dt): files=\(stats.files) changed=\(stats.changed) events=\(stats.events)")
    }

    // 30-day report
    let (start, end) = Period.month.dayBounds()
    print("\n=== AgentPulse report  \(start) … \(end) ===")
    for category in UsageCategory.allCases {
        let totals = cache.totalsByTool(start: start, end: end, category: category)
        let grand = totals.values.reduce(0, +)
        guard grand > 0 else { continue }
        let byTool = ToolKind.allCases
            .compactMap { t in totals[t].map { "\(t.display) \($0)" } }
            .joined(separator: "  ·  ")
        print("\n## \(category.display)  (total \(grand))   \(byTool)")
        for ic in cache.topItems(start: start, end: end, tool: nil, category: category, limit: 12) {
            let label = category == .mcp ? Normalize.displayServer(ic.item) : ic.item
            let count = String(ic.count)
            let countPad = String(repeating: " ", count: max(0, 6 - count.count)) + count
            let labelPad = label.count >= 34 ? label : label + String(repeating: " ", count: 34 - label.count)
            print("  \(countPad)  \(labelPad) \(ic.tool.display)")
        }
    }
    print("")
} catch {
    err("FATAL: \(error)")
    exit(1)
}
