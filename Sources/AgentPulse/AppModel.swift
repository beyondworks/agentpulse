import Foundation
import SwiftUI
import ServiceManagement
import AgentPulseCore

enum PeriodKind: String, CaseIterable, Identifiable {
    case week = "주간"
    case month = "월간"
    case all = "전체"
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
    @Published var toolFilter: ToolKind? = nil          // nil == all tools
    @Published var category: UsageCategory = .mcp
    @Published var showZero = false

    // Status
    @Published var lastUpdated = "—"
    @Published var isCollecting = false

    // Results
    @Published var topItems: [ItemCount] = []
    @Published var trend: [DayToolCount] = []
    @Published var dayTokens: [String: DayTokens] = [:]   // Claude tokens per day (hover tooltip)
    @Published var totalsByTool: [ToolKind: Int] = [:]
    @Published var grandTotal = 0
    @Published var categoryHasData: [UsageCategory: Bool] = [:]   // per category, in current period + tool
    @Published var toolHasData: [ToolKind: Bool] = [:]            // per tool, in current period + category
    @Published var ranking: [RankRow] = []

    @Published var launchAtLogin = false

    // Live monitoring (plan usage + per-session context)
    @Published var liveSessions: [SessionCtx] = []
    @Published var ctxThreshold = 80
    @Published var liveEnabled = true
    @Published var window1M = true          // default context window when unknown (1M vs 200k)

    private struct CtxState { var armed = true; var lastNotified = Date.distantPast }
    private var ctxState: [String: CtxState] = [:]

    let cachePath: String
    let autoRefresh: Bool                   // false in snapshot/debug runs — view must not self-refresh
    private let cache: UsageCache?
    private var timer: Timer?
    private var liveTimer: Timer?
    private var watcher: FileWatcher?

    init(autoCollect: Bool = true) {
        autoRefresh = autoCollect
        let home = NSHomeDirectory()
        cachePath = home + "/Library/Application Support/AgentPulse/usage.db"
        cache = try? UsageCache(path: cachePath)
        if let t = ProcessInfo.processInfo.environment["AGENTPULSE_CTX_THRESHOLD"], let n = Int(t) { ctxThreshold = n }
        refreshLoginState()
        reload()
        guard autoCollect else { return }
        Notifier.shared.prepare()
        collect()   // refresh data on launch
        liveTick()

        // Real-time refresh: watch the source dirs and re-collect on any write.
        watcher = FileWatcher(paths: [home + "/.claude/projects",
                                      home + "/.codex/sessions",
                                      home + "/.hermes/profiles"], latency: 1.5) { [weak self] in
            Task { @MainActor in self?.collect(); self?.liveTick() }
        }
        watcher?.start()

        // Safety-net polls in case FSEvents misses (and for the plan-usage cache).
        // `.common` mode so they keep firing while the popover is open, and the body
        // runs SYNCHRONOUSLY on the main run loop (no Task hop whose delivery can lag
        // behind while the popover is up) — the timer already fires on main.
        func every(_ s: TimeInterval, _ body: @escaping @MainActor () -> Void) -> Timer {
            let t = Timer(timeInterval: s, repeats: true) { _ in
                MainActor.assumeIsolated { body() }
            }
            RunLoop.main.add(t, forMode: .common)
            return t
        }
        timer = every(120) { [weak self] in self?.collect() }
        liveTimer = every(8) { [weak self] in self?.liveTick() }

        // Every popover open = an implicit full refresh (popover window becomes key).
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.collect(); self?.liveTick() }
        }
    }

    func liveTick() {
        let sessions = LiveUsage.activeSessions(withinMinutes: 15,
                                                defaultWindow: window1M ? 1_000_000 : 200_000)
        liveSessions = sessions
        guard liveEnabled else { return }

        let now = Date()
        var pending: [SessionCtx] = []
        for s in sessions where s.hasContext {   // alerts only make sense with a known window (Claude)
            var st = ctxState[s.sessionId] ?? CtxState()
            if s.usedPercent >= Double(ctxThreshold) {
                if st.armed && now.timeIntervalSince(st.lastNotified) > 600 {   // ≤1 alert / session / 10 min
                    pending.append(s); st.armed = false; st.lastNotified = now
                }
            } else if s.usedPercent < Double(ctxThreshold) - 10 {                // re-arm after compaction
                st.armed = true
            }
            ctxState[s.sessionId] = st
        }
        // Forget sessions that are no longer active.
        let active = Set(sessions.map { $0.sessionId })
        ctxState = ctxState.filter { active.contains($0.key) }

        guard !pending.isEmpty else { return }
        if pending.count > 3 {                                                  // coalesce a burst
            let list = pending.prefix(6).map { "\($0.project) \(Int($0.usedPercent))%" }.joined(separator: ", ")
            Notifier.shared.fire(title: "AgentPulse — \(pending.count)개 세션 컨텍스트 \(ctxThreshold)%+",
                                 body: "\(list) · /compact 권장", id: "ctx-summary")
        } else {
            for s in pending {
                Notifier.shared.fire(title: "AgentPulse — 컨텍스트 \(Int(s.usedPercent))%",
                                     body: "/compact 권장 · \(s.project) (\(s.model), \(s.shortId))",
                                     id: "ctx-\(s.sessionId)")
            }
        }
    }

    var period: Period {
        switch periodKind {
        case .week:   return .week
        case .month:  return .month
        case .all:    return .all
        }
    }

    func reload() {
        guard let cache else { return }
        let (s, e) = period.dayBounds()
        topItems = cache.topItems(start: s, end: e, tool: toolFilter, category: category, limit: 12)
        trend = cache.dailyTrend(start: s, end: e, tool: toolFilter, category: category)
        dayTokens = cache.dailyTokens(start: s, end: e)
        totalsByTool = cache.totalsByTool(start: s, end: e, category: category)
        grandTotal = cache.grandTotal(start: s, end: e, category: category, tool: toolFilter)
        // Data-presence flags so the tabs can show where data actually lives.
        categoryHasData = Dictionary(uniqueKeysWithValues: UsageCategory.allCases.map {
            ($0, cache.grandTotal(start: s, end: e, category: $0, tool: toolFilter) > 0)
        })
        toolHasData = Dictionary(uniqueKeysWithValues: ToolKind.allCases.map {
            ($0, (totalsByTool[$0] ?? 0) > 0)
        })
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
