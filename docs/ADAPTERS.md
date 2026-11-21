# Adapters — follow-up plan (not built in this milestone)

Every adapter reads the same pack: `pack.json` → choose a placement → its embedded preset v1 → fallbacks
(`reduceMotion`, `lowPower`) → layout with the C core's numbers → muted playback (loop the trim range, or play once and
hold) → still whenever video can't play. The C core (`HCGBackgroundCore.c`) is plain C11 + libm, so Windows, Linux and
Android (NDK) adapters can compile it as-is; the web adapter ports four small functions (`layout`, `crop_from_zoom`,
`playback_sanitize`, `parse_hex_colour`) and is tested against the same vectors.

Each adapter is done when: it passes the shared conformance pack (below), refuses a `formatVersion` 2 pack, verifies
checksums before use, and has its own restore/uninstall test.

| # | Adapter | Placements | Approach | Restore / risk notes | Effort |
|---|---|---|---|---|---|
| A1 | **Standard iOS / iPadOS** (App Store apps) | App Background, Banner, Loading Screen | Add `HCGAnimationPack` (it is Foundation-only and already builds for iOS) next to `HCGBackgroundKit`; `HCGBackgroundView.setPreset(_:folder:)` with `pack.exportedPreset(.appBackground)`. A small `HCGPackBackgroundView` convenience. | No system surfaces touched. Desktop/Home and Lock Screen video are not possible for App Store apps. | S |
| A2 | **Jailbroken iOS** (HCG Animation Center tweak) | Home Screen (from Desktop), Lock Screen (experimental), app placements via the kit | Today: *Export for iOS* writes a `.hcgbackground` the tweak imports unchanged. Next: let the tweak's Settings import a `.hcgpack` directly and pick the placement (reads `preset.json`/placements; no format change). | Tweak's own recovery (master switch, kill switch, crash auto-disable) applies; still device-untested. | S |
| A3 | **Windows 10/11** | Desktop + app placements | Desktop: a borderless window parented to the `WorkerW` behind the desktop icons, Media Foundation / `MediaPlayerElement` playback, one per monitor; re-attach on Explorer restart and `WM_DISPLAYCHANGE`. App placements: WinUI 3 control. Package with HCG Executable Maker's Windows route. | Restore = destroy the windows (wallpaper untouched); test Explorer crash/restart, sleep/resume, multi-DPI monitors, Focus assist / battery saver → still. | M |
| A4 | **Linux** | Desktop (X11; Wayland where supported) + app placements | GStreamer pipeline (`playbin` + `videocrop`/`videoscale` from the layout numbers). X11: `_NET_WM_WINDOW_TYPE_DESKTOP` window per monitor. Wayland: `wlr-layer-shell` background layer (KDE, Sway, Hyprland); GNOME has no equivalent → report "not possible" there. | Restore = close windows; test monitor hot-plug (RandR / output events), suspend/resume (logind `PrepareForSleep`), power-profiles-daemon power-saver → still. | M |
| A5 | **Android** | Home Screen + Lock Screen (live wallpaper), app placements | `WallpaperService` + Media3 ExoPlayer with `ClippingMediaSource` (trim) and a `TextureView`/`SurfaceTexture` matrix from the layout numbers; `PlayerView` for app placements. Battery Saver → `lowPower`; `Settings.Global.ANIMATOR_DURATION_SCALE == 0` / "Remove animations" → `reduceMotion`. | Restore = user picks another wallpaper (system UI); test `onVisibilityChanged`, process death, rotation, foldables. | M |
| A6 | **Web** | App Background, Banner, Loading Screen | `<video muted playsinline preload="auto" poster>`: fill → `object-fit: cover`, fit → `contain` + background colour, crop → transform from the layout; trim via `currentTime` + `timeupdate` guard (or `#t=start,end`), `playbackRate`, `prefers-reduced-motion` → poster. Fetch `pack.json`, verify with `crypto.subtle.digest('SHA-256')` for downloaded packs. | No system surfaces. Safari autoplay requires `muted playsinline` (always true here). | S |

## Shared conformance pack (to build first)

`conformance/` with tiny generated packs and expected results, run by every adapter's CI:
- the sample pack (every placement must reach "playing" and match the layout rectangles from the C core);
- a `formatVersion: 2` pack (must be refused);
- a pack with a wrong checksum, a missing still, an unsafe file name, an unknown placement (ignored), a placement
  naming a second clip (refused);
- layout vectors (container × media × scaling × crop → rectangle) generated from `HCGBackgroundCore.c`.

## Order

A1 and A6 first (no system integration, quickest proof outside macOS), then A2 (direct `.hcgpack` import in the tweak),
then A3/A4/A5 desktop adapters — each with its own restore tests, like the Mac desktop player.
