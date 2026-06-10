import Foundation

/// Which AI coding/agent tool produced a usage event.
public enum ToolKind: String, CaseIterable, Sendable, Codable {
    case claudeCode = "claude_code"
    case codex
    case hermes

    public var display: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex:      return "Codex"
        case .hermes:     return "Hermes"
        }
    }
}

/// What kind of thing was used.
/// - mcp:   an MCP server tool call (`mcp__server__tool`)
/// - skill: a Skill invocation (Claude `Skill` tool / Hermes `skill_view`)
/// - tool:  a built-in tool / toolset call (Read, Bash, exec_command, terminal, ...)
public enum UsageCategory: String, CaseIterable, Sendable, Codable {
    case mcp
    case skill
    case tool

    public var display: String {
        switch self {
        case .mcp:   return "MCP"
        case .skill: return "Skill"
        case .tool:  return "Tools"
        }
    }
}

/// A single normalized usage event extracted from a source log.
public struct UsageEvent: Sendable {
    public let tool: ToolKind
    public let category: UsageCategory
    public let item: String        // server name / skill name / tool name
    public let day: String         // "yyyy-MM-dd" in local time
    public let profile: String?    // Hermes persona or Claude project (cwd basename)

    public init(tool: ToolKind, category: UsageCategory, item: String, day: String, profile: String?) {
        self.tool = tool
        self.category = category
        self.item = item
        self.day = day
        self.profile = profile
    }
}

/// Aggregation key used to fold events into daily buckets before persisting.
public struct EventKey: Hashable, Sendable {
    public let tool: ToolKind
    public let category: UsageCategory
    public let item: String
    public let day: String
    public let profile: String

    public init(_ e: UsageEvent) {
        self.tool = e.tool
        self.category = e.category
        self.item = e.item
        self.day = e.day
        self.profile = e.profile ?? ""
    }
}

/// One (item, count) result for ranking / top-N charts.
public struct ItemCount: Sendable, Identifiable, Hashable {
    public var id: String { tool.rawValue + "|" + item }
    public let tool: ToolKind
    public let item: String
    public let count: Int
    public let lastUsed: String?   // yyyy-MM-dd
    public init(tool: ToolKind, item: String, count: Int, lastUsed: String?) {
        self.tool = tool; self.item = item; self.count = count; self.lastUsed = lastUsed
    }
}

/// Per-day token consumption (Claude only — Codex/Hermes don't log per-message tokens).
/// Used for the trend-chart hover tooltip.
public struct DayTokens: Sendable, Hashable {
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheCreation: Int
    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheCreation = cacheCreation
    }
    /// All tokens that flowed through the model that day (new + generated + cache I/O).
    public var total: Int { input + output + cacheRead + cacheCreation }
    public mutating func add(_ o: DayTokens) {
        input += o.input; output += o.output; cacheRead += o.cacheRead; cacheCreation += o.cacheCreation
    }
}

/// One (day, tool, count) point for the time-series chart.
public struct DayToolCount: Sendable, Identifiable, Hashable {
    public var id: String { day + "|" + tool.rawValue }
    public let day: String
    public let tool: ToolKind
    public let count: Int
    public init(day: String, tool: ToolKind, count: Int) {
        self.day = day; self.tool = tool; self.count = count
    }
}
