# HCG animation pack — format version 1

Identifier `com.hakmicapitalgroup.animation-pack`, `formatVersion` **1**.
Schema: [`schema/hcg-animation-pack-v1.schema.json`](../schema/hcg-animation-pack-v1.schema.json).
Reference implementation: `Packages/HCGAnimationKit/Sources/HCGAnimationPack` (Swift, Foundation only, builds and
tests on Linux). Independent check: [`scripts/validate_pack.py`](../scripts/validate_pack.py) (Python + the JSON Schemas).
Sample: [`Samples/OrbitalCommand.hcgpack`](../Samples/OrbitalCommand.hcgpack).

## Built on what we already own

Before defining anything new I read `HCG-Jailbreak-Research/HCGAnimationCenter` (branch `claude/stoic-gates-07elp7`,
commit `35d9db7`). Its **HCG background preset v1** (`com.hakmicapitalgroup.background-preset`, `HCGBackgroundKit`)
already describes one clip with trim, loop, speed, fill/fit/crop, a still and muted playback, with a pure-C rules
core. So the pack does **not** redefine any of that:

| Part | How the pack uses it |
|---|---|
| `HCGBackgroundCore.c/.h` (limits, trim/speed/still repair, fill/fit/crop geometry, GIF timing) | **Vendored unmodified** (`Packages/HCGAnimationKit/Vendor/VENDORED.md`, checksums enforced in CI). The Swift reader, the Mac renderer and the importer call it directly. |
| Preset v1 document (`preset.json`) | **Embedded unchanged** in every placement (`placements.<id>.preset`). Same keys, same canonical output as `-[HCGBackgroundPreset dictionaryRepresentation]`. |
| Preset v1 schema | Vendored unmodified; the pack schema `$ref`s it for every placement. |
| `.hcgbackground` folder (preset.json + media + still) | A pack folder **also contains `preset.json`** (the default placement), so `+[HCGBackgroundPreset presetWithContentsOfURL:]` opens a `.hcgpack` folder as-is. Any placement can be exported as a standalone `.hcgbackground` (Mac app: *Export … for iOS*; CLI: `hcgpack export-preset`). |
| Reduce Motion / Low Power choices | Same strings as the tweak's `HACKeyReduceMotion` (`still`/`play`) and `HACKeyLowPower` (`still`/`play`/`system`). |
| Error codes | 1–7 are `HCGBackgroundError`'s values; packs add 20–23 (checksum, size, insecure URL, network). |
| Rules: file names are plain names inside the folder; nothing is executed; higher major version refused; unknown keys ignored | Same rules for the pack, the catalog and every placement. |

What the pack adds: **several placements of one clip**, **per-file sizes and SHA-256** (required, because packs
travel), and a **manifest** that ties them together.

## A pack is a folder

```
OrbitalCommand.hcgpack/
  pack.json        the manifest (this document)
  preset.json      the default placement as a plain background preset v1 (for HCGBackgroundKit / iOS)
  media.mp4        the one source clip (H.264/HEVC MP4 or MOV; GIFs are converted to H.264 .mov on import)
  poster.jpg       the poster frame (also the default still)
  still-*.jpg      optional: a placement's own still
```

On macOS the app declares `com.hakmicapitalgroup.animation-pack` as a package type, so Finder shows a pack as one item
and double-clicking imports it.

## pack.json

```json
{
  "format": "com.hakmicapitalgroup.animation-pack",
  "formatVersion": 1,
  "id": "4F1C9A3E-2B7D-4E61-9C05-0D8A7B3E5F21",
  "name": "HCG Orbital Command",
  "created": "2026-11-21T00:00:00Z",
  "generator": { "app": "hcgpack", "version": "0.1.0" },
  "presetFormat": { "format": "com.hakmicapitalgroup.background-preset", "formatVersion": 1 },
  "media": { "file": "media.mp4", "bytes": 3319168, "sha256": "…", "width": 3840, "height": 2160,
             "duration": 12, "origin": "video", "codec": "avc1" },
  "files": [ { "file": "poster.jpg", "bytes": 321060, "sha256": "…", "role": "poster" } ],
  "defaultPlacement": "desktop",
  "placements": {
    "desktop":        { "canvas": {"width": 3456, "height": 2234}, "reduceMotion": "still", "lowPower": "still", "preset": { …preset v1… } },
    "app-background": { "canvas": {"width": 1179, "height": 2556}, "reduceMotion": "still", "lowPower": "still", "preset": { … } },
    "banner":         { "canvas": {"width": 1500, "height": 500},  "reduceMotion": "still", "lowPower": "still", "preset": { … } },
    "loading-screen": { "canvas": {"width": 1179, "height": 2556}, "reduceMotion": "still", "lowPower": "play",  "preset": { … } }
  }
}
```

| Field | Required | Reader behaviour |
|---|---|---|
| `format` | yes | exactly the identifier, else refused (code 1) |
| `formatVersion` | yes | whole number; **higher than the reader's → refused** ("update to use it", code 2) |
| `id` | no | UUID (upper-cased); invalid → refused |
| `name` | no | ≤ 120 UTF-16 units (longer is cut) |
| `media.file` | yes | plain file name, not `pack.json`/`preset.json` |
| `media.bytes`, `media.sha256` | yes | whole number; 64 lowercase hex. `verify` checks both |
| `media.width/height/duration` | yes | display size after rotation and seconds, with the preset v1 limits (16–8192 px, 0.5–600 s) |
| `media.origin`, `media.codec` | no | informational |
| `files[]` | no | every other file with `file`, `bytes`, `sha256`, `role` (`poster`, `still`); duplicates refused |
| `placements` | yes | object; at least one **known** placement. Unknown placement ids are **ignored with a warning** |
| `placements.<id>.preset` | yes | a complete preset v1, read with the preset v1 rules (repairs → warnings, refusals → error naming the placement) |
| … `preset.media.file/width/height/duration` | — | must be the pack's media (**one source clip**), else refused |
| … `preset.media.sha256` | — | if present must equal `media.sha256` (writers always include it) |
| … `preset.still.file` | — | must be listed in `files` |
| `placements.<id>.reduceMotion` | no | `still` (default) \| `play` |
| `placements.<id>.lowPower` | no | `still` (default) \| `play` \| `system` (draw nothing; the normal desktop / host background shows) |
| `placements.<id>.canvas` | no | the aspect the author previewed at; informational (renderers lay out for the real container) |
| `defaultPlacement` | no | must be present; otherwise the first in the order below, with a warning |
| `preset.json` | no | readers use `pack.json`; writers keep `preset.json` equal to the default placement |
| anything else | — | ignored |

Placement order (and ids): `desktop`, `app-background`, `banner`, `loading-screen`.

### Placement presets (defaults for a new pack)

| Placement | Canvas | Scaling | Fallbacks | Notes |
|---|---|---|---|---|
| Desktop | 3456×2234 (16″ MacBook Pro) | fill | RM still · LP still | the Mac desktop player always uses this placement |
| App Background | 1179×2556 portrait | crop (centred, zoom 1) | RM still · LP still | phone-shaped app screens |
| Banner | 1500×500 (3:1) | crop | RM still · LP still | headers, cards |
| Loading Screen | 1179×2556 | fit on `#080C12` | RM still · LP play | whole frame visible; short-lived |

Every placement starts with the whole clip, looping, 1×, muted, the poster as its still; each can then get its own
trim, speed, loop, framing, still and fallbacks. The sample pack uses banner 0.75× zoom 1.15, loading 1.5× fit.

### Rendering a placement (all platforms)

1. Read `pack.json`; refuse a higher `formatVersion`.
2. Pick the placement; read its `preset` with the preset v1 rules.
3. Decide with the fallbacks (`RenderPolicy`): forced still → still; Low Power → `lowPower`; Reduce Motion →
   `reduceMotion`; thermal pressure → still; else play. `system` means draw nothing.
4. Lay out with `hcgbg_layout(container, media, scaling, crop)` — the same numbers everywhere.
5. Play muted; loop the trim range or play it once and hold the last frame; show the still until the first frame and
   whenever playback fails.

## Versioning

- Minor additions (new optional keys, new placement ids) keep `formatVersion: 1`; old readers ignore them.
- Breaking changes increase `formatVersion`; old readers refuse with "update to use it" and never play it wrongly.
- The embedded presets follow the preset v1 rules independently (their own `formatVersion`).
- Writers produce canonical JSON (sorted keys, two-space indent, whole numbers without a fraction), so a pack rebuilt
  from the same inputs is byte-identical. Placement preset ids are derived from the pack id.

## Tools

```bash
cd Packages/HCGAnimationKit && swift build -c release --product hcgpack
```

```bash
.build/release/hcgpack validate ../../Samples/OrbitalCommand.hcgpack
```

```bash
.build/release/hcgpack export-preset ../../Samples/OrbitalCommand.hcgpack app-background ~/Desktop
```

`hcgpack create | set | validate | info | export-preset | catalog | validate-catalog | compatibility` — see the header
of `Sources/hcgpack/main.swift`. `scripts/make-sample-pack.sh --clip <file>` rebuilds the sample from any clip.
