# Compatibility — which placements each platform can actually render

This table is generated from `PlatformSupport.matrix` (`HCGAnimationPack/Compatibility.swift`) — the same data the
Mac app shows under *Online › Platform compatibility*. CI fails if this file and the data disagree
(`scripts/check-compatibility-doc.sh`). Only **macOS** is implemented in this milestone; everything marked 🗺️ is
follow-up work planned in [ADAPTERS.md](ADAPTERS.md).

<!-- BEGIN GENERATED: hcgpack compatibility -->
| Platform | Desktop | App Background | Banner | Loading Screen | Lock Screen (milestone) |
|---|---|---|---|---|---|
| **macOS 14+**<br>HCG Animation Center for Mac + HCGPackPlayer (this repository) | ✅ desktop-level windows per display; system wallpaper never modified | ✅ HCGPackPlayer in any Mac app; proven by the Maker-built demo | ✅ HCGPackPlayer (same renderer, crop placement) | ✅ HCGPackPlayer (same renderer, fit placement) | 🔬 no public API; separate milestone with its own restore tests |
| **iOS / iPadOS (App Store apps)**<br>HCGBackgroundKit (UIKit) reads each placement's embedded preset v1 | ⛔ apps cannot set a video Home Screen wallpaper | 🟡 HCGBackgroundView renders the embedded preset; pack reader adapter planned | 🟡 as above | 🟡 as above | ⛔ apps cannot set a video Lock Screen |
| **iOS (jailbroken, HCG Animation Center tweak)**<br>Export placement → .hcgbackground → tweak import | 🟡 Desktop placement exported as the Home Screen background; tweak is Simulator-tested, not device-tested | 🟡 HCGBackgroundKit, as for App Store apps | 🟡 HCGBackgroundKit | 🟡 HCGBackgroundKit | 🔬 tweak's Lock Screen surface is experimental and off by default |
| **Windows 10/11**<br>planned: desktop host window behind icons (WorkerW) + Media Foundation | 🗺️ WorkerW technique; must restore on Explorer restart | 🗺️ WinUI MediaPlayerElement / WebView2 | 🗺️ as above | 🗺️ as above | ⛔ Windows lock screen takes still images only |
| **Linux**<br>planned: GStreamer; X11 desktop window / Wayland layer-shell | 🗺️ X11 _NET_WM_WINDOW_TYPE_DESKTOP; Wayland only where wlr-layer-shell exists (not GNOME) | 🗺️ GStreamer / GTK video widget | 🗺️ as above | 🗺️ as above | ⛔ depends on the screen locker; not portable |
| **Android**<br>planned: WallpaperService + Media3 ExoPlayer | 🗺️ live wallpaper (Home Screen) | 🗺️ Media3 PlayerView | 🗺️ as above | 🗺️ as above | 🗺️ live wallpaper can apply to the lock screen on most devices |
| **Web**<br>planned: <video muted playsinline> + object-fit (mapping in the iOS project's PRESET-FORMAT.md) | ⛔ browsers cannot set the desktop | 🗺️ fill → cover, fit → contain, crop → transform | 🗺️ as above | 🗺️ as above | ⛔ — |

✅ renders (verified here) · 🟡 renderer exists, pack adapter or device test pending · 🗺️ adapter planned · ⛔ not possible for third-party software · 🔬 research milestone
<!-- END GENERATED -->

## What "renders" means for macOS here

Verified on GitHub-hosted **macOS 26.7.2 virtual machines (Apple M1 Virtual, Xcode 26.6)** by the self-test and the
Maker demo (see [VERIFICATION.md](VERIFICATION.md)). It has **not yet been run on the MacBook Pro M4 Max with
macOS 27**; that pass is [MAC-HARDWARE-CHECKLIST.md](MAC-HARDWARE-CHECKLIST.md).

## Requirements of the Mac app

| | |
|---|---|
| macOS | 14.0 or later (built with the macOS 26.5 SDK; target machine: macOS 27) |
| CPU | Apple silicon and Intel (universal binary) |
| Media | H.264 or HEVC in MP4/MOV, GIF (converted to H.264 on import); up to 8192 px per side, 0.5 s – 10 min |
| Sound | never played (format v1 is muted) |
| Permissions | none (no screen recording, no accessibility, no network unless you use an online catalog) |
