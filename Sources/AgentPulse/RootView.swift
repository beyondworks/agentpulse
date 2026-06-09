import SwiftUI
import Charts
import AgentPulseCore

private let toolColorDomain = ["Claude Code", "Codex", "Hermes"]
private let toolColorRange: [Color] = [.orange, .blue, .purple]

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controls
            toolTotals
            charts
            rankingSection
            footer
        }
        .padding(14)
        .onChange(of: model.periodKind) { _, _ in model.reload() }
        .onChange(of: model.category) { _, _ in model.reload() }
        .onChange(of: model.toolFilter) { _, _ in model.reload() }
        .onChange(of: model.showZero) { _, _ in model.reload() }
        .onChange(of: model.customStart) { _, _ in model.reload() }
        .onChange(of: model.customEnd) { _, _ in model.reload() }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "chart.bar.xaxis").foregroundStyle(.tint)
            Text("AgentPulse").font(.headline)
            Text("· \(model.category.display) 호출 \(model.grandTotal.formatted())회")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if model.isCollecting { ProgressView().controlSize(.small) }
            Text("업데이트 \(model.lastUpdated)").font(.caption).foregroundStyle(.secondary)
            Button { model.collect() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).disabled(model.isCollecting)
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $model.periodKind) {
                    ForEach(PeriodKind.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).fixedSize()

                if model.periodKind == .custom {
                    DatePicker("", selection: $model.customStart, displayedComponents: .date)
                        .labelsHidden()
                    Text("~").foregroundStyle(.secondary)
                    DatePicker("", selection: $model.customEnd, displayedComponents: .date)
                        .labelsHidden()
                }
                Spacer()
                Picker("", selection: $model.category) {
                    ForEach(UsageCategory.allCases, id: \.self) { Text($0.display).tag($0) }
                }.pickerStyle(.segmented).fixedSize()
            }
            HStack {
                Picker("", selection: $model.toolFilter) {
                    Text("전체").tag(ToolKind?.none)
                    ForEach(ToolKind.allCases, id: \.self) { Text($0.display).tag(ToolKind?.some($0)) }
                }.pickerStyle(.segmented)
            }
        }
    }

    // MARK: Tool totals row

    private var toolTotals: some View {
        HStack(spacing: 10) {
            ForEach(ToolKind.allCases, id: \.self) { tool in
                let n = model.totalsByTool[tool] ?? 0
                HStack(spacing: 6) {
                    Circle().fill(color(for: tool.display)).frame(width: 8, height: 8)
                    Text(tool.display).font(.caption)
                    Text(n.formatted()).font(.caption.bold())
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
                .opacity(n == 0 ? 0.45 : 1)
            }
            Spacer()
        }
    }

    // MARK: Charts

    private var charts: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("기간 추세").font(.caption).foregroundStyle(.secondary)
                trendChart
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("많이 쓴 항목 Top 12").font(.caption).foregroundStyle(.secondary)
                topChart
            }
        }
        .frame(height: 260)
    }

    @ViewBuilder private var trendChart: some View {
        if trendPoints.isEmpty {
            emptyBox
        } else {
            Chart(trendPoints) { p in
                BarMark(x: .value("날짜", p.date, unit: .day),
                        y: .value("호출", p.count))
                    .foregroundStyle(by: .value("툴", p.toolName))
            }
            .chartForegroundStyleScale(domain: toolColorDomain, range: toolColorRange)
            .chartLegend(.hidden)
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
        }
    }

    @ViewBuilder private var topChart: some View {
        if model.topItems.isEmpty {
            emptyBox
        } else {
            Chart(model.topItems) { ic in
                BarMark(x: .value("호출", ic.count),
                        y: .value("항목", label(for: ic)))
                    .foregroundStyle(by: .value("툴", ic.tool.display))
            }
            .chartForegroundStyleScale(domain: toolColorDomain, range: toolColorRange)
            .chartYScale(domain: topLabelsInOrder)
            .chartLegend(.hidden)
        }
    }

    private var emptyBox: some View {
        RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4))
            .overlay(Text("데이터 없음").font(.caption).foregroundStyle(.secondary))
    }

    // MARK: Ranking

    private var rankingSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("랭킹").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("미사용(0회) 포함", isOn: $model.showZero)
                    .toggleStyle(.checkbox).font(.caption)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.ranking.enumerated()), id: \.element.id) { idx, row in
                        HStack(spacing: 8) {
                            Text("\(idx + 1)").font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                            Circle().fill(color(for: row.tool.display)).frame(width: 7, height: 7)
                            Text(displayItem(row)).font(.callout).lineLimit(1)
                            Spacer(minLength: 8)
                            if let lu = row.lastUsed {
                                Text(lu).font(.caption2).foregroundStyle(.tertiary)
                            }
                            Text(row.count.formatted()).font(.callout.monospacedDigit().bold())
                                .frame(width: 56, alignment: .trailing)
                                .foregroundStyle(row.count == 0 ? .secondary : .primary)
                        }
                        .padding(.vertical, 3)
                        Divider()
                    }
                }
            }
            .frame(minHeight: 120)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )).toggleStyle(.checkbox).font(.caption)
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless).font(.caption)
        }
    }

    // MARK: Helpers

    private func color(for toolDisplay: String) -> Color {
        guard let i = toolColorDomain.firstIndex(of: toolDisplay) else { return .gray }
        return toolColorRange[i]
    }

    private func label(for ic: ItemCount) -> String {
        let raw = model.category == .mcp ? Normalize.displayServer(ic.item) : ic.item
        return raw.count > 30 ? String(raw.prefix(29)) + "…" : raw
    }

    private func displayItem(_ row: RankRow) -> String {
        model.category == .mcp ? Normalize.displayServer(row.item) : row.item
    }

    private var topLabelsInOrder: [String] {
        // Swift Charts orders a categorical Y axis by the domain; reverse so the
        // largest bar sits at the top.
        model.topItems.map { label(for: $0) }.reversed()
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
