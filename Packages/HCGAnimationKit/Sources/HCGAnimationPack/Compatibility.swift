//
//  Compatibility.swift
//  HCGAnimationPack — Hakmi Capital Group
//
//  Which placements each platform can actually render, today. One table used by the Mac app, `hcgpack compatibility`
//  and docs/COMPATIBILITY.md (CI checks that the document matches this data).
//

import Foundation

public enum SupportLevel: String, Sendable {
    /// Implemented and verified in this repository.
    case renders
    /// A renderer exists (another HCG project or the format's own rules) but not yet verified with packs.
    case rendererExists = "renderer-exists"
    /// Adapter planned as follow-up work.
    case planned
    /// The platform does not let third-party software do this.
    case notPossible = "not-possible"
    /// Under investigation in its own milestone.
    case research

    public var symbol: String {
        switch self {
        case .renders: return "✅"
        case .rendererExists: return "🟡"
        case .planned: return "🗺️"
        case .notPossible: return "⛔"
        case .research: return "🔬"
        }
    }
}

public struct PlatformSupport: Sendable {
    public struct Cell: Sendable {
        public var level: SupportLevel
        public var note: String
    }

    public var platform: String
    public var adapter: String
    /// Keyed by placement id; plus "lock-screen" (separate milestone, not a v1 placement).
    public var cells: [String: Cell]

    public static let columns: [(id: String, title: String)] =
        PlacementID.allCases.map { ($0.rawValue, $0.title) } + [("lock-screen", "Lock Screen (milestone)")]

    private static func c(_ l: SupportLevel, _ n: String) -> Cell { Cell(level: l, note: n) }

    public static let matrix: [PlatformSupport] = [
        PlatformSupport(platform: "macOS 14+", adapter: "HCG Animation Center for Mac + HCGPackPlayer (this repository)", cells: [
            "desktop": c(.renders, "desktop-level windows per display; system wallpaper never modified"),
            "app-background": c(.renders, "HCGPackPlayer in any Mac app; proven by the Maker-built demo"),
            "banner": c(.renders, "HCGPackPlayer (same renderer, crop placement)"),
            "loading-screen": c(.renders, "HCGPackPlayer (same renderer, fit placement)"),
            "lock-screen": c(.research, "no public API; separate milestone with its own restore tests"),
        ]),
        PlatformSupport(platform: "iOS / iPadOS (App Store apps)", adapter: "HCGBackgroundKit (UIKit) reads each placement's embedded preset v1", cells: [
            "desktop": c(.notPossible, "apps cannot set a video Home Screen wallpaper"),
            "app-background": c(.rendererExists, "HCGBackgroundView renders the embedded preset; pack reader adapter planned"),
            "banner": c(.rendererExists, "as above"),
            "loading-screen": c(.rendererExists, "as above"),
            "lock-screen": c(.notPossible, "apps cannot set a video Lock Screen"),
        ]),
        PlatformSupport(platform: "iOS (jailbroken, HCG Animation Center tweak)", adapter: "Export placement → .hcgbackground → tweak import", cells: [
            "desktop": c(.rendererExists, "Desktop placement exported as the Home Screen background; tweak is Simulator-tested, not device-tested"),
            "app-background": c(.rendererExists, "HCGBackgroundKit, as for App Store apps"),
            "banner": c(.rendererExists, "HCGBackgroundKit"),
            "loading-screen": c(.rendererExists, "HCGBackgroundKit"),
            "lock-screen": c(.research, "tweak's Lock Screen surface is experimental and off by default"),
        ]),
        PlatformSupport(platform: "Windows 10/11", adapter: "planned: desktop host window behind icons (WorkerW) + Media Foundation", cells: [
            "desktop": c(.planned, "WorkerW technique; must restore on Explorer restart"),
            "app-background": c(.planned, "WinUI MediaPlayerElement / WebView2"),
            "banner": c(.planned, "as above"),
            "loading-screen": c(.planned, "as above"),
            "lock-screen": c(.notPossible, "Windows lock screen takes still images only"),
        ]),
        PlatformSupport(platform: "Linux", adapter: "planned: GStreamer; X11 desktop window / Wayland layer-shell", cells: [
            "desktop": c(.planned, "X11 _NET_WM_WINDOW_TYPE_DESKTOP; Wayland only where wlr-layer-shell exists (not GNOME)"),
            "app-background": c(.planned, "GStreamer / GTK video widget"),
            "banner": c(.planned, "as above"),
            "loading-screen": c(.planned, "as above"),
            "lock-screen": c(.notPossible, "depends on the screen locker; not portable"),
        ]),
        PlatformSupport(platform: "Android", adapter: "planned: WallpaperService + Media3 ExoPlayer", cells: [
            "desktop": c(.planned, "live wallpaper (Home Screen)"),
            "app-background": c(.planned, "Media3 PlayerView"),
            "banner": c(.planned, "as above"),
            "loading-screen": c(.planned, "as above"),
            "lock-screen": c(.planned, "live wallpaper can apply to the lock screen on most devices"),
        ]),
        PlatformSupport(platform: "Web", adapter: "planned: <video muted playsinline> + object-fit (mapping in the iOS project's PRESET-FORMAT.md)", cells: [
            "desktop": c(.notPossible, "browsers cannot set the desktop"),
            "app-background": c(.planned, "fill → cover, fit → contain, crop → transform"),
            "banner": c(.planned, "as above"),
            "loading-screen": c(.planned, "as above"),
            "lock-screen": c(.notPossible, "—"),
        ]),
    ]

    public static func markdownTable() -> String {
        var lines = ["| Platform | " + columns.map(\.title).joined(separator: " | ") + " |",
                     "|---|" + columns.map { _ in "---" }.joined(separator: "|") + "|"]
        for p in matrix {
            let cells = columns.map { col -> String in
                guard let c = p.cells[col.id] else { return "—" }
                return "\(c.level.symbol) \(c.note)"
            }
            lines.append("| **\(p.platform)**<br>\(p.adapter) | " + cells.joined(separator: " | ") + " |")
        }
        lines.append("")
        lines.append("✅ renders (verified here) · 🟡 renderer exists, pack adapter or device test pending · 🗺️ adapter planned · ⛔ not possible for third-party software · 🔬 research milestone")
        return lines.joined(separator: "\n")
    }
}
