import SwiftUI
import AppKit
import AgentPulseCore

/// The app icon (bars-on-squircle), loaded once from the bundled AppIcon.icns.
/// Nil in unpackaged dev runs (raw `.build/...` binary) — callers fall back to
/// an SF Symbol so the UI still renders during development/snapshots.
enum AppAssets {
    static let icon: NSImage? = {
        guard let path = Bundle.main.path(forResource: "AppIcon", ofType: "icns") else { return nil }
        return NSImage(contentsOfFile: path)
    }()

    /// Draw the three ascending bars (no plate) using the current fill colour,
    /// matching the app-icon proportions. Shared by the menu-bar glyph and the
    /// debug renderer.
    static func drawBars(size pt: CGFloat) {
        let u = pt / 18.0                          // 18-unit design box
        let barW = 3.0 * u, gap = 2.0 * u
        let heights: [CGFloat] = [6.5 * u, 9.2 * u, 13.0 * u]   // short → tall
        let totalW = barW * 3 + gap * 2
        let x0 = (pt - totalW) / 2, baseY = 2.5 * u
        for (i, h) in heights.enumerated() {
            let r = NSRect(x: x0 + CGFloat(i) * (barW + gap), y: baseY, width: barW, height: h)
            NSBezierPath(roundedRect: r, xRadius: 0.7 * u, yRadius: 0.7 * u).fill()
        }
    }

    /// Menu-bar status-item glyph: bars only, no background, as a TEMPLATE image so
    /// macOS tints it to match other menu-bar icons (white on the dark menu bar).
    static func menuBarGlyph(_ pt: CGFloat = 18) -> NSImage {
        let img = NSImage(size: NSSize(width: pt, height: pt))
        img.lockFocus()
        NSColor.black.setFill()
        drawBars(size: pt)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }
}

@main
struct AgentPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model)
                .frame(width: 640, height: 500)
        } label: {
            Image(nsImage: AppAssets.menuBarGlyph())
        }
        .menuBarExtraStyle(.window)
    }
}

/// Pure menu-bar app: no Dock icon, no main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var snapWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        // Headless render of the SwiftUI view (charts) — no AppKit controls.
        if let idx = args.firstIndex(of: "--render"), idx + 1 < args.count {
            renderAndExit(to: args[idx + 1], categoryRaw: idx + 2 < args.count ? args[idx + 2] : nil)
            return
        }
        // Native capture of the real view hierarchy (controls + list) via cacheDisplay.
        if let idx = args.firstIndex(of: "--snap"), idx + 1 < args.count {
            snap(to: args[idx + 1], categoryRaw: idx + 2 < args.count ? args[idx + 2] : nil)
            return
        }
        // Render the menu-bar glyph as it appears in the bar (white on dark) for review.
        if let idx = args.firstIndex(of: "--glyph"), idx + 1 < args.count {
            renderGlyph(to: args[idx + 1]); return
        }
        NSApp.setActivationPolicy(.accessory)
    }

    private func renderGlyph(to path: String) {
        let S: CGFloat = 176
        let img = NSImage(size: NSSize(width: S, height: S))
        img.lockFocus()
        NSColor(white: 0.13, alpha: 1).setFill()                       // dark menu-bar-like bg
        NSRect(x: 0, y: 0, width: S, height: S).fill()
        NSColor.white.setFill()
        AppAssets.drawBars(size: S)                                    // bars as they'll be tinted
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        exit(0)
    }

    @MainActor
    private func makeModel(_ categoryRaw: String?) -> AppModel {
        let model = AppModel(autoCollect: false)
        let env = ProcessInfo.processInfo.environment
        model.periodKind = .month
        if env["AGENTPULSE_FAKE_PERIOD"] == "all" { model.periodKind = .all }
        if let raw = env["AGENTPULSE_FAKE_TOOL"], let t = ToolKind(rawValue: raw) { model.toolFilter = t }
        if let raw = categoryRaw, let cat = UsageCategory(rawValue: raw) { model.category = cat }
        model.reload()
        model.liveEnabled = false   // populate live data for the snapshot without firing alerts
        model.liveTick()
        if ProcessInfo.processInfo.environment["AGENTPULSE_FAKE_COLLECTING"] != nil { model.isCollecting = true }
        if ProcessInfo.processInfo.environment["AGENTPULSE_FAKE_SESSIONS"] != nil {
            let d = Date(timeIntervalSince1970: 0)
            model.liveSessions = [
                SessionCtx(sessionId: "fake01aaaa", project: "agentpulse", model: "claude-opus-4-8", ctxTokens: 820_000, windowSize: 1_000_000, mtime: d),
                SessionCtx(sessionId: "fake02bbbb", project: "intranet", model: "claude-sonnet-4-6", ctxTokens: 130_000, windowSize: 200_000, mtime: d),
                SessionCtx(sessionId: "fake03cccc", project: ".claude", model: "claude-opus-4-8", ctxTokens: 480_000, windowSize: 1_000_000, mtime: d),
                SessionCtx(sessionId: "fake04dddd", project: "linkbrain", model: "claude-sonnet-4-6", ctxTokens: 62_000, windowSize: 200_000, mtime: d),
                SessionCtx(sessionId: "fake05eeee", project: "auto-video", model: "claude-opus-4-8", ctxTokens: 910_000, windowSize: 1_000_000, mtime: d),
                SessionCtx(sessionId: "fake06ffff", project: "leanax", model: "claude-sonnet-4-6", ctxTokens: 24_000, windowSize: 200_000, mtime: d),
                SessionCtx(tool: .codex, sessionId: "fake07codex", project: "product-design", model: "codex", ctxTokens: 0, windowSize: 0, mtime: Date()),
                SessionCtx(tool: .hermes, sessionId: "fake08hermes", project: "hyojung", model: "hermes", ctxTokens: 0, windowSize: 0, mtime: Date()),
            ]
        }
        return model
    }

    @MainActor
    private func renderAndExit(to path: String, categoryRaw: String?) {
        let view = RootView(model: makeModel(categoryRaw)).frame(width: 640, height: 500)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        if let img = renderer.nsImage,
           let tiff = img.tiffRepresentation,
           let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            FileHandle.standardError.write(Data("rendered \(path)\n".utf8))
        }
        exit(0)
    }

    /// Render the real AppKit-backed view (native segmented controls, toggles, ranking
    /// list) into a PNG using the app's own draw — no Screen Recording permission needed.
    @MainActor
    private func snap(to path: String, categoryRaw: String?) {
        NSApp.setActivationPolicy(.regular)
        let host = NSHostingView(rootView: RootView(model: makeModel(categoryRaw)).frame(width: 640, height: 500))
        host.frame = NSRect(x: 0, y: 0, width: 640, height: 500)
        let win = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = host
        win.title = "AgentPulse"
        win.center()
        win.orderFrontRegardless()
        snapWindow = win
        // Let SwiftUI + Charts complete a render pass before capturing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                FileHandle.standardError.write(Data("snapped \(path)\n".utf8))
            }
            exit(0)
        }
    }
}
