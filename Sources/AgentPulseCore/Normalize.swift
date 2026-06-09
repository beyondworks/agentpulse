import Foundation

public enum Normalize {
    /// Extract the MCP server name from a tool name like `mcp__server__tool`.
    ///
    /// Tool names use the form `mcp__{server}__{tool}`. The `__` (double
    /// underscore) is the separator; server names themselves contain only
    /// single underscores, so splitting on `__` is unambiguous.
    ///   mcp__playwright__browser_navigate          -> playwright
    ///   mcp__plugin_telegram_telegram__reply       -> plugin_telegram_telegram
    ///   mcp__912a3582-...__execute_sql             -> 912a3582-...
    public static func mcpServer(from name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let parts = name.components(separatedBy: "__")
        // parts[0] == "mcp"
        guard parts.count >= 2 else { return nil }
        if parts.count == 2 { return parts[1].isEmpty ? nil : parts[1] }
        // server is everything between the first and last segment
        let server = parts[1..<(parts.count - 1)].joined(separator: "__")
        return server.isEmpty ? nil : server
    }

    /// Some MCP servers are exposed under opaque UUID-ish names. Provide a
    /// friendlier short label for display (first 8 chars + ellipsis).
    public static func displayServer(_ server: String) -> String {
        // UUID pattern: 8-4-4-4-12 hex
        let uuidish = server.range(of: #"^[0-9a-f]{8}-[0-9a-f]{4}-"#, options: .regularExpression) != nil
        if uuidish { return String(server.prefix(8)) + "…" }
        return server
    }
}
