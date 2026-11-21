# HCG Executable Maker — bundled animation pack (proof)

**Result: no change to HCG Executable Maker was needed.** The demo is built with Maker's existing Swift → `.app` route
and its existing packaging contract (`AppPackaging.json`, schema `hcg-app-packaging/1`). Maker is used at
`F1r3srp3nt/HCG-Executable-Maker@2842998e778d687cf7653100c280875df93f8f1a` (`main`), unmodified.

## What I checked in Maker first

| Maker piece | Finding | Used how |
|---|---|---|
| New Build wizard, Swift packages (`docs/SWIFT-MACOS.md`) | Import folder/ZIP → choose `Package.swift` → evaluate after trust → choose product → configure → package → build → verify | The demo is a normal SwiftPM package in `Samples/MakerDemo` |
| SwiftPM resources (`Bundle.module`) | Maker puts resource bundles at the **app root**, outside the signed `Contents` ("unsealed contents" — Gatekeeper rejects a downloaded copy) | **Not used**, so the app stays fully sealed |
| Packaging contract `AppPackaging.json` → `resources` | Files copied to `Contents/Resources/…` before signing; destinations validated; each resource checked present after the build ("Contract resources" verification); contract hash re-checked at build time | **Used** — one entry per pack file |
| Contract `bundle.infoPlist` template | HCG sets identity keys, all other template keys are kept | **Used** — carries the opt-in keys |
| Contract resources are files, not folders | A pack folder is listed file by file (5 entries) | Fine for one pack; see "Possible Maker improvement" |
| Headless UI driver (`tools/ui-driver`) + `verify-macos-app.sh` | Drives the real wizard view-models in CI; Maker's own app checks | **Used** in this repository's CI (`maker-demo` job) |

## Opt-in at the project level

Nothing about animation packs is global in Maker. A project opts in with two files it owns:

`Samples/MakerDemo/AppPackaging.json`

```json
{
  "schema": "hcg-app-packaging/1",
  "product": "HCGPackDemo",
  "bundle": { "displayName": "HCG Pack Demo", "identifier": "com.hakmicapitalgroup.packdemo",
              "infoPlist": "Resources/Info.plist", "minimumMacOS": "14.0" },
  "resources": [
    { "source": "../OrbitalCommand.hcgpack/pack.json",   "destination": "Contents/Resources/OrbitalCommand.hcgpack/pack.json",   "required": true },
    { "source": "../OrbitalCommand.hcgpack/preset.json", "destination": "Contents/Resources/OrbitalCommand.hcgpack/preset.json", "required": true },
    { "source": "../OrbitalCommand.hcgpack/media.mp4",   "destination": "Contents/Resources/OrbitalCommand.hcgpack/media.mp4",   "required": true },
    { "source": "../OrbitalCommand.hcgpack/poster.jpg",  "destination": "Contents/Resources/OrbitalCommand.hcgpack/poster.jpg",  "required": true }
  ]
}
```

`Samples/MakerDemo/Resources/Info.plist` (template) adds:

```xml
<key>HCGAnimationPack</key><string>OrbitalCommand.hcgpack</string>
<key>HCGAnimationPlacement</key><string>app-background</string>
```

The app reads those two keys; without them it shows its plain background. No prebuild commands, no helpers, no
network.

## Exact Maker settings used

| Wizard step | Value |
|---|---|
| Import | folder: this repository's root (so `../OrbitalCommand.hcgpack` and `../../Packages/HCGAnimationKit` resolve inside the workspace) |
| Package | `Samples/MakerDemo/Package.swift` (three packages are offered; none is pre-selected) |
| Evaluate | trust confirmed → `swift package dump-package` |
| Product | `HCGPackDemo` (SwiftUI app) |
| Display name / bundle id | `HCG Pack Demo` / `com.hakmicapitalgroup.packdemo` |
| Version / build | from the contract template: `0.1.0` / `1` |
| Minimum macOS | `14.0` (package and contract) |
| Architecture | Apple Silicon (`arm64`) |
| Packaging contract | shown in Configure; confirmed (no commands to run) |
| Formats | `.app`, `.app` as ZIP |
| Signing | ad hoc (Maker default) |

Same thing, as run by CI:

```bash
dotnet maker/tools/ui-driver/bin/Release/net10.0/hcg-ui-driver.dll --source "$PWD/animation-centre" --package Samples/MakerDemo --product HCGPackDemo --name "HCG Pack Demo" --bundle-id com.hakmicapitalgroup.packdemo --arch arm64 --formats app,zip --confirm-contract --output "$OUT" --screenshots "$OUT/screens" --prefix packdemo
```

## What the finished app is checked for

1. Maker's own post-build verification (part of the build) and `tools/ui-driver/verify-macos-app.sh`: Info.plist,
   `codesign --verify --strict --deep`, slices, launch with `open`, screenshot.
2. `Contents/Resources/OrbitalCommand.hcgpack` is **byte-identical** to `Samples/OrbitalCommand.hcgpack`
   (`diff -r`), the Info.plist carries the opt-in keys, and the signature covers it.
3. Launched with `--self-check`, the app reports: pack loaded and every checksum verified, App Background placement,
   state *Playing*, playback time advancing, video on screen, the poster still loaded; then it clicks its own
   **Launch Mission** button and **Animate background** toggle through `NSWindow.sendEvent` (the normal hit-testing
   path) and both work — the background never takes the click.
4. `--simulate-playback-failure`: the still is shown and the button still works.
5. **Offline:** run under `sandbox-exec` with all networking denied — still plays.
6. The ZIP Maker produced contains the same app and the same pack.

## Build evidence

See [VERIFICATION.md](VERIFICATION.md#maker-built-demo) for the CI run, the logs' key lines and the artifact
(`hcg-pack-demo-built-by-maker`).

## Possible Maker improvement (not required, not done)

A contract `resources` entry that accepts a **folder** (or a dedicated `animationPacks` key that also runs
`hcgpack validate` and records the pack's checksum in Maker's verification) would turn the five entries into one and
make Maker check the pack itself, not just the presence of its files. If wanted, it belongs on its own Maker branch.
