import Foundation

/// Incremental JSONL reader: reads only the bytes appended since `fromOffset`,
/// returning complete lines plus the new offset (one past the last newline).
enum JSONL {
    struct Chunk { let lines: [Data]; let newOffset: Int64 }

    static func newLines(path: String, fromOffset: Int64, fileSize: Int64) -> Chunk {
        // File rotated/truncated since last run → restart from the beginning.
        let start = fromOffset > fileSize ? 0 : fromOffset
        guard let fh = FileHandle(forReadingAtPath: path) else { return Chunk(lines: [], newOffset: start) }
        defer { try? fh.close() }
        do { try fh.seek(toOffset: UInt64(max(0, start))) }
        catch { return Chunk(lines: [], newOffset: start) }
        let data = (try? fh.readToEnd()) ?? Data()
        guard let lastNL = data.lastIndex(of: 0x0A) else { return Chunk(lines: [], newOffset: start) }
        let consumed = data[...lastNL]
        let newOffset = start + Int64(consumed.count)
        let lines = consumed.split(separator: 0x0A, omittingEmptySubsequences: true).map { Data($0) }
        return Chunk(lines: lines, newOffset: newOffset)
    }
}

/// Claude Code transcripts: `~/.claude/projects/**/*.jsonl` (incl. subagents).
/// Each line is a message; `message.content[]` tool_use blocks carry MCP/Skill/tool calls.
enum ClaudeParser {
    static func events(line: Data) -> [UsageEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]],
              let day = TimeUtil.day(fromISO: obj["timestamp"] as? String)
        else { return [] }

        let project = (obj["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        var out: [UsageEvent] = []
        for block in content {
            guard block["type"] as? String == "tool_use",
                  let name = block["name"] as? String, !name.isEmpty else { continue }
            if name == "Skill" {
                if let input = block["input"] as? [String: Any],
                   let skill = input["skill"] as? String, !skill.isEmpty {
                    out.append(UsageEvent(tool: .claudeCode, category: .skill, item: skill, day: day, profile: project))
                }
            } else if name.hasPrefix("mcp__") {
                if let server = Normalize.mcpServer(from: name) {
                    out.append(UsageEvent(tool: .claudeCode, category: .mcp, item: server, day: day, profile: project))
                }
            } else {
                out.append(UsageEvent(tool: .claudeCode, category: .tool, item: name, day: day, profile: project))
            }
        }
        return out
    }

    /// Token consumption for one transcript line, from `message.usage`. Only assistant
    /// messages carry usage; returns nil for everything else (and for zero-token lines).
    static func tokens(line: Data) -> (day: String, tokens: DayTokens)? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let day = TimeUtil.day(fromISO: obj["timestamp"] as? String)
        else { return nil }
        func n(_ k: String) -> Int { (usage[k] as? NSNumber)?.intValue ?? 0 }
        let t = DayTokens(input: n("input_tokens"), output: n("output_tokens"),
                          cacheRead: n("cache_read_input_tokens"),
                          cacheCreation: n("cache_creation_input_tokens"))
        return t.total > 0 ? (day, t) : nil
    }
}

/// Codex rollout sessions: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`.
/// New format wraps items in `{type:"response_item", timestamp, payload:{...}}`;
/// old format has bare items with no per-line timestamp (fall back to filename date).
/// Codex flattens most MCP tool names, so only clean `mcp__server__tool` names are
/// attributed to MCP; everything else is a built-in tool.
enum CodexParser {
    static func events(line: Data, fileDay: String) -> [UsageEvent] {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return [] }
        let payload = (obj["payload"] as? [String: Any]) ?? obj
        guard let type = payload["type"] as? String,
              type == "function_call" || type == "custom_tool_call" || type == "local_shell_call"
        else { return [] }

        let day = TimeUtil.day(fromISO: obj["timestamp"] as? String) ?? fileDay
        guard let name = payload["name"] as? String, !name.isEmpty else {
            if type == "local_shell_call" {
                return [UsageEvent(tool: .codex, category: .tool, item: "local_shell", day: day, profile: nil)]
            }
            return []
        }
        if name.hasPrefix("mcp__"), let server = Normalize.mcpServer(from: name) {
            return [UsageEvent(tool: .codex, category: .mcp, item: server, day: day, profile: nil)]
        }
        return [UsageEvent(tool: .codex, category: .tool, item: name, day: day, profile: nil)]
    }

    /// Extract `YYYY-MM-DD` from a rollout filename for old-format lines that lack a timestamp.
    static func fileDay(from filename: String) -> String? {
        guard let r = filename.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        return String(filename[r])
    }
}
