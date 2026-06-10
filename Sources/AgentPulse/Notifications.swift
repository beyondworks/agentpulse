import Foundation
import AppKit
import UserNotifications

/// Local macOS notifications. Primary path is UNUserNotificationCenter (per-session
/// identifiers so repeats update instead of stacking). When that isn't usable — bare
/// binary with no bundle identity, or the user denied permission — it routes through
/// `osascript display notification`, which always works for a local utility.
@MainActor
final class Notifier {
    static let shared = Notifier()

    private var useUN = false      // UNUserNotificationCenter authorized & usable
    private var asked = false

    /// Call once at launch. Safe even when running as a bare binary.
    func prepare() {
        guard !asked else { return }
        asked = true
        // UNUserNotificationCenter.current() traps without a bundle identity.
        guard Bundle.main.bundleIdentifier != nil else { useUN = false; return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.useUN = granted }
        }
    }

    func fire(title: String, body: String, id: String) {
        FileHandle.standardError.write(Data("[notify] \(title) — \(body) [\(id)]\n".utf8))
        if useUN, Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { error in
                if error != nil { Task { @MainActor in self.osascript(title: title, body: body) } }
            }
        } else {
            osascript(title: title, body: body)
        }
    }

    private func osascript(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        // Quote-safe: AppleScript string literals use double quotes; swap any out.
        let t = title.replacingOccurrences(of: "\"", with: "'")
        let b = body.replacingOccurrences(of: "\"", with: "'")
        p.arguments = ["-e", "display notification \"\(b)\" with title \"\(t)\""]
        try? p.run()
    }
}
