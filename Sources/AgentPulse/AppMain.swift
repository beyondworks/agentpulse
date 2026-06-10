import SwiftUI
import AppKit
import AgentPulseCore

@main
struct AgentPulseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            RootView(model: model)
                .frame(width: 640, height: 500)
        } label: {
            Image(systemName: "chart.bar.xaxis")
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
        NSApp.setActivationPolicy(.accessory)
    }

    @MainActor
    private func makeModel(_ categoryRaw: String?) -> AppModel {
        let model = AppModel(autoCollect: false)
        model.periodKind = .month
        if let raw = categoryRaw, let cat = UsageCategory(rawValue: raw) { model.category = cat }
        model.reload()
        model.liveEnabled = false   // populate live data for the snapshot without firing alerts
        model.liveTick()
        model.planUsage = LiveUsage.planUsage()   // cache only — no network/Keychain in snapshots
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
