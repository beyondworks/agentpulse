import Foundation
import SwiftUI
import ServiceManagement
import AgentPulseCore

enum PeriodKind: String, CaseIterable, Identifiable {
    case week = "주간"
    case month = "월간"
    case custom = "기간지정"
    var id: String { rawValue }
}

/// One row in the ranking list (used items + optional 0-usage installed items).
struct RankRow: Identifiable, Hashable {
    let tool: ToolKind
    let item: String
    let count: Int
    let lastUsed: String?
    var id: String { tool.rawValue + "|" + item }
}

@MainActor
final class AppModel: ObservableObject {
    // Controls
    @Published var periodKind: PeriodKind = .week
    @Published var customStart = Calendar.current.date(byAdding: .day, value: -7, to: Date())!
    @Published var customEnd = Date()
    @Published var toolFilter: ToolKind? = nil          // nil == all tools
    @Published var category: UsageCategory = .mcp
    @Published var showZero = false

    // Status
    @Published var lastUpdated = "—"
    @Published var isCollecting = false

    // Results
    @Published var topItems: [ItemCount] = []
    @Published var trend: [DayToolCount] = []
    @Published var totalsByTool: [ToolKind: Int] = [:]
    @Published var grandTotal = 0
    @Published var ranking: [RankRow] = []

    @Published var launchAtLogin = false

    let cachePath: String
    private let cache: UsageCache?
    private var timer: Timer?

    init(autoCollect: Bool = true) {
        let home = NSHomeDirectory()
        cachePath = home + "/Library/Application Support/AgentPulse/usage.db"
        cache = try? UsageCache(path: cachePath)
        refreshLoginState()
        reload()
        guard autoCollect else { return }
        collect()   // refresh data on launch
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.collect() }
        }
    }

    var period: Period {
        switch periodKind {
        case .week:   return .week
        case .month:  return .month
        case .custom: return .custom(customStart, customEnd)
        }
    }

    func reload() {
        guard let cache else { return }
        let (s, e) = period.dayBounds()
        topItems = cache.topItems(start: s, end: e, tool: toolFilter, category: category, limit: 12)
        trend = cache.dailyTrend(start: s, end: e, tool: toolFilter, category: category)
        totalsByTool = cache.totalsByTool(start: s, end: e, category: category)
        grandTotal = cache.grandTotal(start: s, end: e, category: category, tool: toolFilter)
        lastUpdated = cache.meta("last_collected").map(Self.pretty) ?? "—"
        ranking = buildRanking(start: s, end: e)
    }

    private func buildRanking(start: String, end: String) -> [RankRow] {
        guard let cache else { return [] }
        let used = cache.topItems(start: start, end: end, tool: toolFilter, category: category, limit: 5000)
        var rows = used.map { RankRow(tool: $0.tool, item: $0.item, count: $0.count, lastUsed: $0.lastUsed) }
        if showZero {
            let usedKeys = Set(used.map { $0.tool.rawValue + "|" + $0.item })
            for (tool, items) in cache.installedItems(tool: toolFilter, category: category) {
                for it in items where !usedKeys.contains(tool.rawValue + "|" + it) {
                    rows.append(RankRow(tool: tool, item: it, count: 0, lastUsed: nil))
                }
            }
        }
        return rows.sorted { $0.count > $1.count }
    }

    /// Run an incremental collection on a background connection (WAL lets the UI keep reading).
    func collect() {
        guard !isCollecting else { return }
        isCollecting = true
        let path = cachePath
        Task.detached(priority: .utility) {
            if let c = try? UsageCache(path: path) {
                _ = Collector(cache: c).collectAll()
            }
            await MainActor.run {
                self.isCollecting = false
                self.reload()
            }
        }
    }

    // MARK: - Login item

    func refreshLoginState() {
        if #available(macOS 13.0, *) {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Registration only works from a real .app bundle; ignore in dev runs.
        }
        refreshLoginState()
    }

    static func pretty(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        guard let d = f.date(from: iso) else { return "—" }
        let out = DateFormatter()
        out.dateFormat = "M/d HH:mm"
        return out.string(from: d)
    }
}
