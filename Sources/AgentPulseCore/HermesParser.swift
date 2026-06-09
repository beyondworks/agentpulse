import Foundation

/// Hermes per-persona stores: `~/.hermes/profiles/{persona}/state.db`.
/// The `messages` table holds assistant rows whose `tool_calls` JSON column is an
/// OpenAI-style array `[{function:{name, arguments}}]`. `skill_view` calls name the
/// skill in `arguments.name`. Hermes has no MCP concept — only toolsets + skills.
enum HermesParser {
    /// Read new assistant rows (id > fromRowid) read-only; emit events; return the new max id.
    static func collect(dbPath: String, persona: String, fromRowid: Int64,
                        emit: (UsageEvent) -> Void) -> Int64 {
        guard FileManager.default.fileExists(atPath: dbPath),
              let src = try? SQLiteDB(path: dbPath, readOnly: true) else { return fromRowid }

        var maxId = fromRowid
        try? src.query("""
        SELECT id, timestamp, tool_calls, tool_name
        FROM messages WHERE id > ? AND role='assistant' ORDER BY id
        """, bind: [.int(fromRowid)]) { r in
            let id = r.int(0)
            if id > maxId { maxId = id }
            let day = TimeUtil.day(fromEpoch: r.double(1))

            if let tc = r.text(2), tc.hasPrefix("[") {
                guard let arr = (try? JSONSerialization.jsonObject(with: Data(tc.utf8))) as? [[String: Any]] else { return }
                for e in arr {
                    let fn = e["function"] as? [String: Any]
                    guard let name = (fn?["name"] as? String) ?? (e["name"] as? String), !name.isEmpty else { continue }
                    emit(UsageEvent(tool: .hermes, category: .tool, item: name, day: day, profile: persona))
                    if name == "skill_view" || name == "skill_run" || name == "skill" {
                        if let skill = skillName(from: fn?["arguments"]) {
                            emit(UsageEvent(tool: .hermes, category: .skill, item: skill, day: day, profile: persona))
                        }
                    }
                }
            } else if let tn = r.text(3), !tn.isEmpty {
                emit(UsageEvent(tool: .hermes, category: .tool, item: tn, day: day, profile: persona))
            }
        }
        return maxId
    }

    /// `arguments` may be a JSON string or an already-parsed dict; the skill name is under `name`.
    static func skillName(from arguments: Any?) -> String? {
        var dict = arguments as? [String: Any]
        if dict == nil, let s = arguments as? String,
           let d = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] {
            dict = d
        }
        guard let dict else { return nil }
        let name = (dict["name"] as? String) ?? (dict["skill"] as? String) ?? (dict["skill_name"] as? String)
        if let name, !name.isEmpty { return name }
        return nil
    }
}
