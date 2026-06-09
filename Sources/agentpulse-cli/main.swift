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
