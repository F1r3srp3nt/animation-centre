# Milestone L — real Lock Screen video on macOS (separate, not started)

The first milestone animates the **desktop** only. A video on the **Lock Screen** is a different problem and is
tracked here with its own compatibility and restore tests, so it can't destabilise the desktop player.

## Why it is separate

- macOS has **no public API** for a third-party Lock Screen video. The login window / lock screen is drawn by system
  processes (loginwindow, WallpaperAgent) outside the user's session windows; our desktop-level windows are not shown
  there, and they are paused while the screen is locked (by design: `SystemMonitor` suspension "the screen is
  locked").
- macOS 14+ shows the *system* wallpaper (including Apple's aerial videos) on the Lock Screen. Any approach that makes
  *our* clip appear there would have to change system wallpaper state or system-owned assets — exactly what the desktop
  player avoids so that "stop" is always a clean restore.

## Candidate approaches to research (each must pass the gates below before any code ships)

| | Approach | Concern |
|---|---|---|
| L1 | Set a **still** (the pack's poster) as the system wallpaper for the lock screen only while our desktop player runs, restore the previous wallpaper on stop | Uses public API (`NSWorkspace.setDesktopImageURL`) but changes user state → needs bullet-proof restore, multi-display, multi-Space |
| L2 | Use the system's **dynamic/aerial wallpaper** mechanism with our clip | Undocumented asset formats and locations; may break on any macOS update; possibly against platform rules |
| L3 | Screen-saver module (`.saver`) playing the pack, with "show screen saver before lock" | Public API (ScreenSaver.framework), but it's the screen saver, not the Lock Screen itself |

## Gates (all required before shipping)

1. **Compatibility matrix:** macOS 14, 15, 26, 27 × Apple silicon/Intel × single/multi-display × FileVault on/off ×
   fast user switching. Unknown OS versions → feature disabled with a reason.
2. **Restore tests:** after stop, quit, crash (`kill -9`), uninstall, OS update, and logout/login, the lock screen and
   desktop wallpaper are byte-identical to before (record `desktopImageURL` + options per screen and per Space;
   compare screenshots of the lock screen).
3. **Repeated apply/stop ×50** with lock/unlock between each, on the M4 Max.
4. **Sleep/wake and lid close/open** while locked; external display connect/disconnect while locked.
5. A one-click "Restore system wallpaper" in the menu bar that works even if the app's state is lost.

## Status

Not started. The desktop player never changes the system wallpaper; its self-test asserts this
("System wallpaper never modified").
