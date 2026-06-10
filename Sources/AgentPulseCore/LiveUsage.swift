import Foundation
import CryptoKit
import Security

/// Claude Max subscription usage (5-hour + weekly windows), as cached by the
/// OMC HUD after it calls `api.anthropic.com/api/oauth/usage`. We only read the
/// cache file — no credentials, no network. Meaningful only for subscription
/// (OAuth) sessions; under API-key auth there is no quota and the cache goes stale.
public struct PlanUsage: Sendable {
    public let fiveHourPercent: Int?
    public let weeklyPercent: Int?
    public let sonnetWeeklyPercent: Int?
    public let fiveHourResetsAt: Date?
    public let weeklyResetsAt: Date?
    public let updatedAt: Date       // cache file mtime (freshness)
    public let sourceFile: String
    public let errorReason: String?  // OMC fetch failure: "auth" | "no_credentials" | nil
    public let lastSuccessAt: Date?  // last time OMC actually got real numbers

    public init(fiveHourPercent: Int?, weeklyPercent: Int?, sonnetWeeklyPercent: Int?,
                fiveHourResetsAt: Date?, weeklyResetsAt: Date?, updatedAt: Date, sourceFile: String,
                errorReason: String? = nil, lastSuccessAt: Date? = nil) {
        self.fiveHourPercent = fiveHourPercent
        self.weeklyPercent = weeklyPercent
        self.sonnetWeeklyPercent = sonnetWeeklyPercent
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.updatedAt = updatedAt
        self.sourceFile = sourceFile
        self.errorReason = errorReason
        self.lastSuccessAt = lastSuccessAt
    }

    /// True when the cache carries real numbers recent enough to trust as "current".
    public func isFresh(maxAgeHours: Double = 6) -> Bool {
        guard fiveHourPercent != nil || weeklyPercent != nil else { return false }
        return Date().timeIntervalSince(updatedAt) < maxAgeHours * 3600
    }
}

/// Live context-window occupancy for one active Claude Code session.
public struct SessionCtx: Sendable, Identifiable {
    public var id: String { sessionId }
    public let sessionId: String
    public let project: String
    public let model: String
    public let ctxTokens: Int
    public let windowSize: Int
    public let mtime: Date

    public var usedPercent: Double { windowSize > 0 ? Double(ctxTokens) / Double(windowSize) * 100 : 0 }
    public var shortId: String { String(sessionId.prefix(6)) }

    public init(sessionId: String, project: String, model: String, ctxTokens: Int, windowSize: Int, mtime: Date) {
        self.sessionId = sessionId; self.project = project; self.model = model
        self.ctxTokens = ctxTokens; self.windowSize = windowSize; self.mtime = mtime
    }
}

public enum LiveUsage {
    // MARK: - Plan usage

    public static func planUsage(home: String = NSHomeDirectory()) -> PlanUsage? {
        let dir = home + "/.claude/plugins/oh-my-claudecode"
        // Source-specific cache (`-anthropic`) is OMC's current truth; legacy base file is a fallback.
        let candidates = ["/.usage-cache-anthropic.json", "/.usage-cache.json"].map { dir + $0 }
        var best: PlanUsage?
        for path in candidates {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let data = FileManager.default.contents(atPath: path),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let d = (obj["data"] as? [String: Any]) ?? [:]
            let mtime = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let errFlag = (obj["error"] as? Bool) ?? false
            let reason = errFlag ? (obj["errorReason"] as? String ?? "error") : nil
            let lastSuccess = (obj["lastSuccessAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            let pu = PlanUsage(
                fiveHourPercent: intVal(d["fiveHourPercent"]),
                weeklyPercent: intVal(d["weeklyPercent"]),
                sonnetWeeklyPercent: intVal(d["sonnetWeeklyPercent"]),
                fiveHourResetsAt: TimeUtil.isoDate(d["fiveHourResetsAt"]),
                weeklyResetsAt: TimeUtil.isoDate(d["weeklyResetsAt"]),
                updatedAt: mtime,
                sourceFile: (path as NSString).lastPathComponent,
                errorReason: reason,
                lastSuccessAt: lastSuccess
            )
            // Newest cache file wins — it reflects OMC's most recent fetch (data *or* error).
            if best == nil || pu.updatedAt > best!.updatedAt { best = pu }
        }
        return best
    }

    // MARK: - Plan usage (live fetch)

    private struct OAuthCreds {
        let accessToken: String
        let expiresAt: Double?      // epoch milliseconds
        let refreshToken: String?
        var isExpired: Bool {
            guard let e = expiresAt else { return false }
            return e <= Date().timeIntervalSince1970 * 1000
        }
    }

    /// Fetch live plan usage from Anthropic's OAuth usage endpoint using the Claude
    /// Code CLI credentials. READ-ONLY: the token is used only if it is still valid
    /// (no refresh, no write-back), so this can never rotate the token or affect any
    /// login (CLI or desktop). The token value is never logged. Returns nil when no
    /// valid token exists (e.g. desktop-app-only users) — the UI then shows a hint.
    public static func fetchPlanUsage(home: String = NSHomeDirectory()) async -> PlanUsage? {
        guard let creds = readOAuthCreds(home: home), !creds.isExpired else { return nil }
        guard let json = await requestUsage(token: creds.accessToken) else { return nil }
        return parseUsage(json)
    }

    /// Read OAuth creds from the file and the Keychain; return whichever has the
    /// later expiry. The in-process Keychain read is tried first — it triggers the
    /// proper "AgentPulse wants to use Claude Code-credentials" prompt (one-time
    /// "Always Allow"), unlike the `security` subprocess which doesn't prompt
    /// reliably from a GUI app.
    private static func readOAuthCreds(home: String) -> OAuthCreds? {
        [readFileCreds(home: home), readKeychainInProcess(), readKeychainCreds()]
            .compactMap { $0 }
            .max { ($0.expiresAt ?? 0) < ($1.expiresAt ?? 0) }
    }

    /// Read the token via the Security framework, in-process. macOS attributes the
    /// access prompt to AgentPulse itself, so an "Always Allow" grant sticks for
    /// this app. Read-only — we never write or refresh the token.
    private static func readKeychainInProcess() -> OAuthCreds? {
        let service = keychainService()
        let bases: [[String: Any]] = [
            [kSecAttrService as String: service, kSecAttrAccount as String: NSUserName()],
            [kSecAttrService as String: service],
        ]
        for base in bases {
            var q = base
            q[kSecClass as String] = kSecClassGenericPassword
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let raw = String(data: data, encoding: .utf8), let c = parseCreds(raw) {
                return c
            }
        }
        return nil
    }

    private static func keychainService() -> String {
        if let cfg = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !cfg.isEmpty {
            let hash = SHA256.hash(data: Data(cfg.utf8)).map { String(format: "%02x", $0) }.joined().prefix(8)
            return "Claude Code-credentials-\(hash)"
        }
        return "Claude Code-credentials"
    }

    private static func readKeychainCreds() -> OAuthCreds? {
        let service = keychainService()
        let attempts: [[String]] = [
            ["find-generic-password", "-s", service, "-a", NSUserName(), "-w"],
            ["find-generic-password", "-s", service, "-w"],
        ]
        for args in attempts {
            if let raw = runSecurity(args), let c = parseCreds(raw) { return c }
        }
        return nil
    }

    private static func runSecurity(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty else { return nil }
        return s
    }

    private static func readFileCreds(home: String) -> OAuthCreds? {
        guard let data = FileManager.default.contents(atPath: home + "/.claude/.credentials.json"),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return parseCreds(raw)
    }

    private static func parseCreds(_ raw: String) -> OAuthCreds? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let c = (obj["claudeAiOauth"] as? [String: Any]) ?? obj
        guard let token = c["accessToken"] as? String, !token.isEmpty else { return nil }
        return OAuthCreds(accessToken: token,
                          expiresAt: (c["expiresAt"] as? NSNumber)?.doubleValue,
                          refreshToken: c["refreshToken"] as? String)
    }

    private static func requestUsage(token: String) async -> [String: Any]? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }

    private static func parseUsage(_ r: [String: Any]) -> PlanUsage? {
        func pct(_ key: String) -> Int? {
            guard let o = r[key] as? [String: Any], let u = (o["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return max(0, min(100, Int(u.rounded())))
        }
        func reset(_ key: String) -> Date? {
            guard let o = r[key] as? [String: Any] else { return nil }
            return TimeUtil.isoDate(o["resets_at"])
        }
        let five = pct("five_hour"), week = pct("seven_day"), sonnet = pct("seven_day_sonnet")
        guard five != nil || week != nil || sonnet != nil else { return nil }
        return PlanUsage(fiveHourPercent: five, weeklyPercent: week, sonnetWeeklyPercent: sonnet,
                         fiveHourResetsAt: reset("five_hour"), weeklyResetsAt: reset("seven_day"),
                         updatedAt: Date(), sourceFile: "live")
    }

    // MARK: - Active session context

    /// Enumerate Claude Code sessions whose transcript was written within `withinMinutes`.
    /// Context tokens come from the transcript (always live); window size from the
    /// session's statusLine cache when present, else inferred.
    public static func activeSessions(home: String = NSHomeDirectory(),
                                      withinMinutes: Double = 3,
                                      defaultWindow: Int = 1_000_000) -> [SessionCtx] {
        let root = home + "/.claude/projects"
        guard let en = FileManager.default.enumerator(atPath: root) else { return [] }
        let cutoff = Date().addingTimeInterval(-withinMinutes * 60)
        var out: [SessionCtx] = []
        for case let rel as String in en {
            guard rel.hasSuffix(".jsonl"), !rel.contains("/subagents/") else { continue }
            let path = root + "/" + rel
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let mtime = attrs[.modificationDate] as? Date, mtime >= cutoff else { continue }
            guard let tail = tailReadLastUsage(path: path) else { continue }
            let sessionId = (rel as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            let window = windowSize(home: home, sessionId: sessionId,
                                    model: tail.model, ctxTokens: tail.ctxTokens, fallback: defaultWindow)
            out.append(SessionCtx(sessionId: sessionId,
                                  project: projectLabel(tail.cwd),
                                  model: tail.model,
                                  ctxTokens: tail.ctxTokens,
                                  windowSize: window,
                                  mtime: mtime))
        }
        return out.sorted { $0.usedPercent > $1.usedPercent }
    }

    // MARK: - Helpers

    private struct TailInfo { let ctxTokens: Int; let model: String; let cwd: String }

    /// Read the tail of a transcript and pull the most recent assistant `usage`.
    private static func tailReadLastUsage(path: String) -> TailInfo? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        do { try fh.seek(toOffset: start) } catch { return nil }
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return nil }

        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var cwd = ""
        for lineSlice in lines.reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(lineSlice)) as? [String: Any] else { continue }
            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { continue }
            let input = intVal(usage["input_tokens"]) ?? 0
            let cacheRead = intVal(usage["cache_read_input_tokens"]) ?? 0
            let cacheCreate = intVal(usage["cache_creation_input_tokens"]) ?? 0
            let ctx = input + cacheRead + cacheCreate
            guard ctx > 0 else { continue }
            let model = (message["model"] as? String) ?? "claude"
            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            return TailInfo(ctxTokens: ctx, model: model, cwd: cwd)
        }
        return nil
    }

    /// Resolve the context window size: statusLine cache (authoritative, static per
    /// session) → `[1m]` model / observed tokens over 200k → caller default.
    private static func windowSize(home: String, sessionId: String, model: String,
                                   ctxTokens: Int, fallback: Int) -> Int {
        let stdinPath = home + "/.claude/hud/cache/stdin.\(sessionId).json"
        if let data = FileManager.default.contents(atPath: stdinPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cw = obj["context_window"] as? [String: Any],
           let size = intVal(cw["context_window_size"]), size > 0 {
            return size
        }
        if model.contains("[1m]") || ctxTokens > 200_000 { return 1_000_000 }
        return fallback
    }

    private static func projectLabel(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "—" }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? cwd : base
    }

    static func intVal(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let n = v as? NSNumber { return n.intValue }
        return nil
    }
}
