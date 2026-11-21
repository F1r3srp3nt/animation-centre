# HCG Animation Center

Animated backgrounds from your own clips — **Mac studio and desktop player** first, with a **portable animation
pack** that travels to the iOS project, HCG apps built with HCG Executable Maker, and (later) Windows, Linux, Android
and the web. By Hakmi Capital Group.

**Milestone 1 (this branch):** Mac app, pack format + sample pack, Maker-built demo, one-item online catalog.
Release and publishing stay manual: nothing here signs with a Developer ID, notarises, uploads or hosts anything.

| | |
|---|---|
| Mac app | `Apps/HCGAnimationCenter` — SwiftUI editor (library, large live preview, trim, speed, loop, fill/fit/crop, poster frame, four placements), **Apply to Desktop**, menu bar pause / resume / stop, keep-playing-when-editor-closes, still-frame fallback (Reduce Motion, Low Power, heat, unplayable video), catalog |
| Pack format | `Packages/HCGAnimationKit` — `HCGAnimationPack` (Foundation only; builds and tests on Linux), the vendored C rules from the iOS project, `HCGPackPlayer` (AppKit + AVFoundation renderer), `hcgpack` CLI. Spec: [docs/PACK-FORMAT.md](docs/PACK-FORMAT.md) |
| Sample pack | [`Samples/OrbitalCommand.hcgpack`](Samples/OrbitalCommand.hcgpack) — **stand-in** 4K clip (see below) |
| Maker demo | [`Samples/MakerDemo`](Samples/MakerDemo) — a tiny app built **through HCG Executable Maker** that plays the pack as its background: [docs/MAKER-INTEGRATION.md](docs/MAKER-INTEGRATION.md) |
| Catalog | [`catalog/catalog.json`](catalog/catalog.json) — ready to host; fill in `items[0].baseURL`: [docs/CATALOG.md](docs/CATALOG.md) |
| Compatibility | [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) · adapters plan: [docs/ADAPTERS.md](docs/ADAPTERS.md) · Lock Screen milestone: [docs/LOCK-SCREEN-MILESTONE.md](docs/LOCK-SCREEN-MILESTONE.md) |
| Verification | [docs/VERIFICATION.md](docs/VERIFICATION.md) · on your Mac: [docs/MAC-HARDWARE-CHECKLIST.md](docs/MAC-HARDWARE-CHECKLIST.md) |

## Run it on your Mac

Download the `hcg-animation-center-mac` artifact from the latest green **CI** run of this branch (universal, ad-hoc
signed, not notarised: first open with right-click → Open), or build it (Xcode or the Command Line Tools, macOS 14+):

```bash
scripts/build-app.sh
```

```bash
open "build/HCG Animation Center.app"
```

The sample *HCG Orbital Command* is in the library on first launch. Import your own MP4, MOV or GIF with **Import…**
or by dropping files on the window, edit each placement, then **Apply to Desktop** (⌘↩). Control playback from the
menu bar.

## The 4K HCG Orbital Command clip

Your master clip was **not available in the build session**, so the sample pack uses an original, generated stand-in
with the same delivery spec (3840×2160 H.264 MP4, 30 fps, silent, seamless 12 s loop, labelled "STAND-IN" on screen;
`scripts/render_standin_clip.py`). To rebuild the sample pack and both catalogs from the real clip:

```bash
scripts/make-sample-pack.sh --clip /path/to/HCG-Orbital-Command-4K.mp4
```

## How the desktop player restores your desktop

It never changes the system wallpaper. It draws in its own borderless windows at the desktop window level (below the
icons, above the wallpaper), one per display, that ignore the mouse and join every Space. Stop closes them, so the
untouched wallpaper is visible again — also after Quit or a crash. CI asserts the wallpaper setting is identical before
and after, including after 20 apply/stop cycles.

## Repository layout

```
Apps/HCGAnimationCenter/        Mac studio + desktop player (SwiftUI, AppKit, AVFoundation)
Packages/HCGAnimationKit/       HCGBackgroundCore (vendored C) · HCGAnimationPack (portable) · HCGPackPlayer (macOS) · hcgpack
Samples/OrbitalCommand.hcgpack  sample pack;   Samples/catalog.local.json  local catalog used until hosting
Samples/MakerDemo/              Maker-built demo app (AppPackaging.json opt-in)
catalog/catalog.json            ready-to-host catalog (baseURL to fill in)
schema/                         JSON Schemas: pack v1, catalog v1, background preset v1 (vendored)
scripts/                        build-app.sh, make-sample-pack.sh, validate_pack.py, checks
docs/                           specs, compatibility, adapters, verification, checklists
```

## Reference material

The `MotionWallpaper-master(1).zip` mentioned for the workflow was **not attached to the build session**, so it was not
read; the interface and implementation here are original HCG work. The iOS project
(`HCG-Jailbreak-Research/HCGAnimationCenter`, branch `claude/stoic-gates-07elp7`) and HCG Executable Maker (`main`,
`2842998`) were inspected and are reused as described in the docs.
