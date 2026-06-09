import Foundation

/// Best-effort inventory of what is *installed* (the universe), so the UI can
/// show 0-usage items, not only used ones. All lookups are tolerant of missing files.
enum Installed {
    static func claudeMCP(home: String) -> [String] {
        guard let data = FileManager.default.contents(atPath: home + "/.claude.json"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["mcpServers"] as? [String: Any] else { return [] }
        return Array(servers.keys)
    }

    static func claudeSkills(home: String) -> [String] {
        dirNames(home + "/.claude/skills")
    }

    static func codexMCP(home: String) -> [String] {
        guard let text = try? String(contentsOfFile: home + "/.codex/config.toml", encoding: .utf8) else { return [] }
        var names: [String] = []
        let re = try? NSRegularExpression(pattern: #"(?m)^\[mcp_servers\.([^\]]+)\]"#)
        let range = NSRange(text.startIndex..., in: text)
        re?.enumerateMatches(in: text, range: range) { m, _, _ in
            guard let m, let r = Range(m.range(at: 1), in: text) else { return }
            let name = String(text[r]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !name.isEmpty { names.append(name) }
        }
        return names
    }

    static func hermesSkills(home: String) -> [String] {
        var set = Set<String>(dirNames(home + "/.hermes/skills"))
        if let data = FileManager.default.contents(atPath: home + "/.hermes/skills/.usage.json"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            set.formUnion(obj.keys)
        }
        return Array(set)
    }

    private static func dirNames(_ path: String) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return items.filter { !$0.hasPrefix(".") }.filter { name in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: path + "/" + name, isDirectory: &isDir)
            return isDir.boolValue
        }
    }
}
