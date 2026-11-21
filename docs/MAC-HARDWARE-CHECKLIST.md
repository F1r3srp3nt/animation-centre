# Hardware checklist — MacBook Pro M4 Max, macOS 27

**Nothing in this milestone has run on physical Mac hardware yet.** CI ran on GitHub-hosted virtual Macs
(macOS 26.7.2, "Apple M1 (Virtual)"); see [VERIFICATION.md](VERIFICATION.md). This checklist is the first pass on your
MacBook Pro M4 Max with macOS 27 and your real 4K HCG Orbital Command clip. About 30 minutes. Fill in the Result column
and keep `events.log` (path below) with the results.

## 0. Get the build

Either download the `hcg-animation-center-mac` artifact from the latest green CI run (it is ad-hoc signed and not
notarised, so the first open needs right-click → **Open**, or `xattr -dr com.apple.quarantine "HCG Animation Center.app"`),
or build it yourself:

```bash
git clone -b claude/hcg-animation-center-macos-j103uc https://github.com/F1r3srp3nt/animation-centre.git
```

```bash
cd animation-centre && scripts/build-app.sh
```

```bash
open "build/HCG Animation Center.app"
```

Event log: `~/Library/Application Support/HCG Animation Center/Logs/events.log` (menu bar → *Show Event Log*).

## 1. Automated self-test on the real machine

```bash
"build/HCG Animation Center.app/Contents/MacOS/HCGAnimationCenter" --self-test --report ~/Desktop/hcg-self-test.json --screenshots ~/Desktop/hcg-screens
```

It uses its own temporary library and settings. macOS may ask for **Screen Recording** permission for the screenshot
checks (allow it, or they are reported as skipped). Expected: `SELF-TEST PASSED`. The report records
`model` (should be `Mac16,…`), `virtualMachine: no`, `macOS 27…` and your displays.

## 2. Manual checks

| # | Check | How | Expected | Result |
|---|---|---|---|---|
| H1 | Import the real clip | Editor → Import… → your 4K Orbital Command MP4/MOV | Imported; header shows 3840×2160, its codec and duration; poster thumbnail in the library | |
| H2 | Edit | Trim both handles, speed 0.75×, Desktop **Fill**, Banner **Crop** zoom 1.3, Loading Screen **Fit**; *Set Poster Frame Here* | Preview follows each change live; every placement keeps its own settings after switching tabs and relaunching | |
| H3 | Apply to Desktop | **Apply to Desktop** | Clip plays behind the desktop icons on the built-in display; icons and the menu bar stay clickable; no sound | |
| H4 | Menu bar | Menu bar icon → Pause, Resume, Stop and Restore Desktop | Pause freezes the frame; Resume continues; Stop shows your normal wallpaper immediately | |
| H5 | Editor closes, playback continues | Keep "Keep Playing When the Editor Closes" on → apply → close the editor window | Desktop keeps playing; Dock icon disappears; menu bar control remains; *Open Editor…* brings it back | |
| H6 | Editor closes, playback stops | Turn the option off → apply → close the editor | Normal desktop returns and the app quits | |
| H7 | Spaces and full screen | Swipe between Spaces; put an app in full screen; Mission Control | Animation on every desktop Space; nothing over full-screen apps; no flicker after returning | |
| H8 | **External display** | While playing: connect a display, change its arrangement and resolution, disconnect it | A desktop window appears/resizes/disappears with each change; log shows `display … added/resized/removed` | |
| H9 | Clamshell | With an external display: close the lid, then open it | Still correct on the remaining display(s) | |
| H10 | **Sleep / wake** | Apple menu → Sleep (and lid close on battery); wake after > 1 minute | Playback pauses on sleep, resumes on wake; log shows `suspend: the Mac is asleep` / `resume` / `wake` | |
| H11 | Display sleep | `pmset displaysleepnow`, then wake | Pauses, then resumes | |
| H12 | Lock / fast user switching | ⌃⌘Q, unlock; switch to another user and back | Paused while locked / away; resumes after | |
| H13 | **Reduce Motion** | System Settings → Accessibility → Display → Reduce motion | Desktop switches to the poster still within a second; back to video when turned off | |
| H14 | **Low Power Mode** | System Settings → Battery → Low Power Mode → Always | Still frame (default); set the Desktop placement's Low Power to *Normal desktop* → wallpaper shows; turn Low Power off → video returns | |
| H15 | Repeated apply / stop | 20× Apply → Stop (⌘↩ in the editor, Stop in the menu bar) | Every time: plays, then the exact normal wallpaper; memory in Activity Monitor stays flat | |
| H16 | Quit and crash restore | Apply → Quit from the menu bar; apply again → `killall -9 HCGAnimationCenter` | Normal desktop returns both times; System Settings → Wallpaper unchanged | |
| H17 | Resume on launch | Apply → quit → reopen | Resumes the last animation (turn off in the menu bar to disable) | |
| H18 | Export / iOS | *Export Pack…*; *Export App Background for iOS* | `.hcgpack` and `.hcgbackground` folders; `hcgpack validate` passes on the pack | |
| H19 | Catalog | Online › Catalog → Refresh → Download → Apply; then turn Wi-Fi off and relaunch | Poster, size, verified download, works offline; with a bad URL the previous catalog stays | |
| H20 | Energy | Activity Monitor → Energy, 4K desktop playing for 5 minutes | Record the Energy Impact and CPU %; note any fan noise | |

## 3. Send back

`~/Desktop/hcg-self-test.json`, `events.log`, and the Result column. Anything that fails becomes a fix before the
first release build.
