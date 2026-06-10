import SwiftUI
import AppKit
import Charts
import AgentPulseCore

/// Force the enclosing NSScrollView to use a SLIM but SPACE-RESERVING scroller:
/// legacy style keeps its own lane (insets the content so it never overlaps the
/// numbers), and the mini control size makes that lane thin.
private struct SlimScrollers: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { apply(from: v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView) }
    }
    private func apply(from view: NSView) {
        var cur: NSView? = view
        while let v = cur {
            if let sv = v as? NSScrollView {
                sv.scrollerStyle = .legacy
                sv.autohidesScrollers = false
                sv.verticalScroller?.controlSize = .mini
                return
            }
            cur = v.superview
        }
    }
}

private let toolColorDomain = ["Claude Code", "Codex", "Hermes"]
private let toolColorRange: [Color] = [.orange, .blue, .purple]

/// A compact segmented control whose options dim when they hold no data in the
/// current view — so you can see at a glance which tabs are worth clicking
/// (e.g. Codex/Hermes are dimmed under the MCP category but lit under Tools).
private struct DataSegTabs<T: Hashable>: View {
    let options: [(value: T, label: String, hasData: Bool)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.value) { opt in
                let selected = opt.value == selection
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(.caption)
                        .foregroundStyle(selected ? AnyShapeStyle(.primary)
                                         : AnyShapeStyle(opt.hasData ? Color.secondary : Color.secondary.opacity(0.3)))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(opt.hasData ? "" : "이 기간엔 \(opt.label) 데이터 없음")
            }
        }
        .padding(2)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))
        .fixedSize()
    }
}

/// Minimal flow layout: lays subviews left-to-right, wrapping to the next line
/// when they run out of width (used for the active-session pills).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxWidth == .infinity ? max(0, x - spacing) : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            sv.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var hover: TrendHover? = ProcessInfo.processInfo.environment["AGENTPULSE_FAKE_HOVER"] != nil
        ? TrendHover(day: "2026-06-09", tokens: DayTokens(input: 2082326, output: 5236055, cacheRead: 536514081, cacheCreation: 71993660))
        : nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            liveSection
            Divider()
            controls
            trendSection
            rankedList
            footer
        }
        .padding(10)
        .onChange(of: model.periodKind) { _, _ in model.reload() }
        .onChange(of: model.category) { _, _ in model.reload() }
        .onChange(of: model.toolFilter) { _, _ in model.reload() }
        .onChange(of: model.showZero) { _, _ in model.reload() }
        .onChange(of: model.ctxThreshold) { _, _ in model.liveTick() }
        .onChange(of: model.window1M) { _, _ in model.liveTick() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            if let icon = AppAssets.icon {
                Image(nsImage: icon).resizable().frame(width: 17, height: 17)
            } else {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(.tint).font(.subheadline)
            }
            Text("AgentPulse").font(.subheadline.weight(.semibold))
            Text("· \(model.category.display) \(model.grandTotal.formatted())회")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(model.lastUpdated).font(.caption2).foregroundStyle(.tertiary)
            // Fixed-size refresh control: swaps arrow ⇄ spinner in place (opacity only),
            // so a collection starting/finishing never reflows the header — no window jitter.
            Button { model.collect(); model.refreshPlanUsage(viaKeychain: true) } label: {
                ZStack {
                    Image(systemName: "arrow.clockwise").font(.caption)
                        .opacity(model.isCollecting ? 0 : 1)
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                        .opacity(model.isCollecting ? 1 : 0)
                }
                .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless).disabled(model.isCollecting)
        }
    }

    // MARK: Live (plan usage + active-session context) — single row

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("플랜").font(.caption2).foregroundStyle(.secondary)
                planUsageView
                Spacer()
                Toggle("압축알림", isOn: $model.liveEnabled)
                    .toggleStyle(.switch).controlSize(.mini).font(.caption2).fixedSize()
                Stepper("\(model.ctxThreshold)%", value: $model.ctxThreshold, in: 50...95, step: 5)
                    .controlSize(.small).font(.caption2).fixedSize()
            }
            sessionsFlow
        }
    }

    @ViewBuilder private var sessionsFlow: some View {
        if model.liveSessions.isEmpty {
            HStack(spacing: 6) {
                Text("활성 0").font(.caption2).foregroundStyle(.secondary)
                Text("작업중 세션 없음").font(.caption2).foregroundStyle(.tertiary)
            }
        } else {
            FlowLayout(spacing: 6) {
                Text("활성 \(model.liveSessions.count)")
                    .font(.caption2).foregroundStyle(.secondary).padding(.vertical, 3)
                ForEach(model.liveSessions) { sessionPill($0) }
            }
        }
    }

    private func sessionPill(_ s: SessionCtx) -> some View {
        let col = ctxColor(s.usedPercent)
        return HStack(spacing: 5) {
            miniRing(s.usedPercent, col)
            Text("\(s.project) \(Int(s.usedPercent))%").font(.caption2)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(col.opacity(0.14), in: Capsule())
        .help("\(s.model) · \(s.ctxTokens.formatted())/\(s.windowSize.formatted()) tokens · \(s.shortId)")
    }

    private func miniRing(_ pct: Double, _ col: Color) -> some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            Circle().trim(from: 0, to: max(0.03, min(1, pct / 100)))
                .stroke(col, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
    }

    private func ctxColor(_ p: Double) -> Color {
        if p >= Double(model.ctxThreshold) { return .red }
        if p >= Double(model.ctxThreshold) - 15 { return .orange }
        return Color(red: 0.13, green: 0.65, blue: 0.40)
    }

    @ViewBuilder private var planUsageView: some View {
        if let pu = model.planUsage, pu.isFresh() {
            // OMC fetched real numbers recently — show them live.
            HStack(spacing: 5) {
                planCapsule("5h", pu.fiveHourPercent)
                planCapsule("주간", pu.weeklyPercent)
                planCapsule("Son", pu.sonnetWeeklyPercent)
                if let age = planAgeLabel(pu.updatedAt) {
                    Text(age).font(.caption2).foregroundStyle(.tertiary)   // stale-value transparency
                }
            }
            .fixedSize()
            .help("플랜 잔량 마지막 갱신: \(planAgeFull(pu.updatedAt)) (OMC 캐시 · CC 상태줄과 동일 소스)")
        } else if model.planUsage?.errorReason == "auth" {
            // OMC tried today but the OAuth token is expired/invalid — re-login fixes it.
            Text("재로그인 필요").font(.caption2.weight(.medium)).foregroundStyle(.orange)
                .help("잔량 조회용 OAuth 토큰이 만료됐습니다. 터미널에서 `claude /login`으로 재인증하면 OMC가 잔량을 다시 받아오고 여기에 자동 표시됩니다.")
        } else {
            // No usable credentials (desktop-app-only session, or OMC absent).
            Text("데스크톱앱에서 확인").font(.caption2).foregroundStyle(.tertiary)
                .help("Claude 데스크톱앱 구독의 잔량은 보안상 외부 앱이 읽을 수 없습니다. CLI(claude /login)로 로그인된 세션이 있으면 실시간 표시됩니다.")
        }
    }

    /// Short "· N분 전" suffix shown only when the plan value is no longer essentially
    /// live (≥5 min old), so a lagging cache doesn't look like a wrong "real-time" value.
    private func planAgeLabel(_ d: Date) -> String? {
        let mins = Int(Date().timeIntervalSince(d) / 60)
        guard mins >= 5 else { return nil }
        return mins < 60 ? "· \(mins)분 전" : "· \(mins / 60)시간 전"
    }

    private func planAgeFull(_ d: Date) -> String {
        let mins = Int(Date().timeIntervalSince(d) / 60)
        if mins < 1 { return "방금" }
        if mins < 60 { return "\(mins)분 전" }
        return "\(mins / 60)시간 \(mins % 60)분 전"
    }

    @ViewBuilder private func planCapsule(_ label: String, _ pct: Int?) -> some View {
        if let p = pct {
            HStack(spacing: 3) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text("\(p)%").font(.caption2.weight(.semibold)).foregroundStyle(severityColor(Double(p), warn: 75, alert: 90))
            }
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
    }

    private func severityColor(_ v: Double, warn: Double, alert: Double) -> Color {
        if v >= alert { return .red }
        if v >= warn { return .orange }
        return .primary
    }

    private func agoText(_ d: Date) -> String {
        let days = Int(Date().timeIntervalSince(d) / 86400)
        if days >= 1 { return "\(days)일전" }
        let hours = Int(Date().timeIntervalSince(d) / 3600)
        return hours >= 1 ? "\(hours)시간전" : "방금"
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $model.periodKind) {
                    ForEach(PeriodKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                legendRow
            }
            HStack(spacing: 8) {
                DataSegTabs(options:
                    [(ToolKind?.none, "전체", model.toolHasData.values.contains(true))]
                    + ToolKind.allCases.map { (ToolKind?.some($0), $0.display, model.toolHasData[$0] ?? false) },
                    selection: $model.toolFilter)
                Spacer()
                DataSegTabs(options:
                    UsageCategory.allCases.map { ($0, $0.display, model.categoryHasData[$0] ?? false) },
                    selection: $model.category)
            }
        }
    }

    private var legendRow: some View {
        HStack(spacing: 9) {
            ForEach(ToolKind.allCases, id: \.self) { tool in
                let n = model.totalsByTool[tool] ?? 0
                HStack(spacing: 3) {
                    Circle().fill(color(for: tool.display)).frame(width: 6, height: 6)
                    Text("\(tool.display) \(n.formatted())").font(.caption2).lineLimit(1)
                }.opacity(n == 0 ? 0.5 : 1)
            }
        }
        .fixedSize()   // never wrap/compress the legend into two lines
    }

    // MARK: Trend (sole chart)

    private var trendSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("기간 추세").font(.caption2).foregroundStyle(.secondary)
                if let h = hover { trendHoverLabel(h) }
            }
            trendChart.frame(height: 108)
        }
    }

    @ViewBuilder private var trendChart: some View {
        if trendPoints.isEmpty {
            emptyBox
        } else {
            Chart {
                ForEach(trendPoints) { p in
                    BarMark(x: .value("날짜", p.date, unit: .day),
                            y: .value("호출", p.count))
                        .foregroundStyle(by: .value("툴", p.toolName))
                }
                if let h = hover, let d = TimeUtil.date(fromDay: h.day) {
                    RuleMark(x: .value("날짜", d, unit: .day))
                        .foregroundStyle(.secondary.opacity(0.4))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .chartForegroundStyleScale(domain: toolColorDomain, range: toolColorRange)
            .chartLegend(.hidden)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let pt):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let x = pt.x - geo[plotFrame].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    let day = TimeUtil.day(from: date)
                                    hover = TrendHover(day: day, tokens: model.dayTokens[day])
                                }
                            case .ended:
                                hover = nil
                            }
                        }
                }
            }
        }
    }

    /// One-line token summary shown beside "기간 추세" while hovering a day.
    @ViewBuilder private func trendHoverLabel(_ h: TrendHover) -> some View {
        if let t = h.tokens, t.total > 0 {
            (Text(TrendHover.short(h.day) + " · ").foregroundStyle(.secondary)
             + Text("Claude ").foregroundStyle(.tertiary)
             + Text(fmtTokens(t.total)).foregroundStyle(.primary).fontWeight(.semibold)
             + Text("  입력 \(fmtTokens(t.input)) · 출력 \(fmtTokens(t.output)) · 캐시 \(fmtTokens(t.cacheRead + t.cacheCreation))").foregroundStyle(.tertiary))
                .font(.caption2).lineLimit(1)
        } else {
            Text("\(TrendHover.short(h.day)) · 토큰 데이터 없음").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    private struct TrendHover {
        let day: String
        let tokens: DayTokens?
        /// "2026-06-09" → "6/9"
        static func short(_ day: String) -> String {
            let p = day.split(separator: "-")
            guard p.count == 3, let m = Int(p[1]), let d = Int(p[2]) else { return day }
            return "\(m)/\(d)"
        }
    }

    private var emptyBox: some View {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
            .overlay(
                VStack(spacing: 4) {
                    Text("데이터 없음").font(.caption2).foregroundStyle(.secondary)
                    if let hint = emptyHint {
                        Text(hint).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            )
    }

    /// When the current tool+category view is empty but the selected tool has data
    /// under other categories, point there (e.g. "Codex는 Tools 탭에 있어요").
    private var emptyHint: String? {
        let others = UsageCategory.allCases.filter {
            $0 != model.category && (model.categoryHasData[$0] ?? false)
        }
        guard !others.isEmpty else { return nil }
        let tabs = others.map { $0.display }.joined(separator: "·")
        let who = model.toolFilter?.display ?? "데이터"
        return "\(who)는 \(tabs) 탭에 있어요"
    }

    // MARK: Ranked bar list (merged "top items" + ranking)

    private var rankingMax: Int { max(1, model.ranking.map { $0.count }.max() ?? 1) }

    private var rankedList: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("많이 쓴 항목 · 랭킹").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Toggle("미사용(0회) 포함", isOn: $model.showZero).toggleStyle(.checkbox).font(.caption2)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.ranking.enumerated()), id: \.element.id) { idx, row in
                        rankRow(idx: idx, row: row)
                        Divider()
                    }
                }
                .background(SlimScrollers())
            }
            .frame(minHeight: 150)
        }
    }

    private func rankRow(idx: Int, row: RankRow) -> some View {
        let ratio = max(0.0, Double(row.count) / Double(rankingMax))
        let col = color(for: row.tool.display)
        return HStack(spacing: 8) {
            Text("\(idx + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 16, alignment: .trailing)
            Circle().fill(col).frame(width: 6, height: 6)
            Text(displayItem(row)).font(.callout).lineLimit(1).frame(width: 180, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary.opacity(0.5))
                Capsule().fill(col).scaleEffect(x: ratio, y: 1, anchor: .leading)
            }
            .frame(height: 7).opacity(row.count == 0 ? 0.3 : 1)
            if let lu = row.lastUsed {
                Text(lu).font(.caption2).foregroundStyle(.tertiary).frame(width: 70, alignment: .trailing)
            } else {
                Color.clear.frame(width: 70, height: 1)
            }
            Text(row.count.formatted()).font(.callout.monospacedDigit().weight(.medium))
                .lineLimit(1).frame(width: 58, alignment: .trailing)
                .foregroundStyle(row.count == 0 ? .secondary : .primary)
        }
        .padding(.vertical, 3)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )).toggleStyle(.checkbox).font(.caption2)
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption2)
        }
    }

    // MARK: Helpers

    private func color(for toolDisplay: String) -> Color {
        guard let i = toolColorDomain.firstIndex(of: toolDisplay) else { return .gray }
        return toolColorRange[i]
    }

    private func displayItem(_ row: RankRow) -> String {
        model.category == .mcp ? Normalize.displayServer(row.item) : row.item
    }

    private struct TrendPoint: Identifiable {
        let id = UUID()
        let date: Date
        let toolName: String
        let count: Int
    }

    private var trendPoints: [TrendPoint] {
        model.trend.compactMap { d in
            guard let date = TimeUtil.date(fromDay: d.day) else { return nil }
            return TrendPoint(date: date, toolName: d.tool.display, count: d.count)
        }
    }
}
