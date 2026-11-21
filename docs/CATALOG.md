# Online catalog — format version 1

Identifier `com.hakmicapitalgroup.animation-catalog`, `formatVersion` **1**.
Schema: [`schema/hcg-animation-catalog-v1.schema.json`](../schema/hcg-animation-catalog-v1.schema.json).
Implementation: `Catalog`, `CatalogURLs`, `CatalogStore` in `HCGAnimationPack`; UI: *Online › Catalog* in the Mac app.

## The ready-to-host manifest

[`catalog/catalog.json`](../catalog/catalog.json) lists one item, **HCG Orbital Command**, with every file's size and
SHA-256. **The one field to fill in is `items[0].baseURL`:**

```json
"baseURL": "",
```

Set it to the **HTTPS URL of the folder that holds the pack's files, ending with `/`**, for example
`"https://<your-host>/hcg/animations/OrbitalCommand.hcgpack/"`. Until then the app shows the item as
*Not hosted yet*.

Alternative: if you host `catalog.json` **in the same folder as** `OrbitalCommand.hcgpack/`, you can set
`"baseURL": "OrbitalCommand.hcgpack/"` instead (relative URLs resolve against the catalog's URL).

## Hosting (manual — nothing is published by this repository)

1. Upload the three files of `Samples/OrbitalCommand.hcgpack/` that the catalog lists — `pack.json`, `media.mp4`,
   `poster.jpg` — to one folder on an HTTPS host. (`preset.json` is for iOS tools and is not downloaded.)
2. Fill in `baseURL` in `catalog/catalog.json` and upload the catalog anywhere on HTTPS.
3. In the Mac app: *Catalog › Catalog URL* → paste the catalog's URL → Refresh.
4. Check: `hcgpack validate-catalog catalog.json` and `python3 scripts/validate_pack.py --catalog catalog.json`.

If you replace the clip (`scripts/make-sample-pack.sh --clip <master>`), the script regenerates both catalogs with the
new sizes and checksums; upload the new files and the new catalog together.

## Until you choose a host

The app ships with `Samples/catalog.local.json` (same item, `baseURL` relative to the local file) and uses it by
default, so the catalog, poster, size, download, verification and offline cache all work with the supplied clip on
your Mac. *Use bundled* switches back to it.

## Client rules

| Rule | Behaviour |
|---|---|
| Transport | Catalog: `https` (or `file` before hosting). Plain `http` and URLs with a user name/password are refused. Files: `https`, or `file` only when the catalog itself is local. |
| Display | Poster (verified against its checksum, then cached), name, summary, total size, resolution, duration. |
| Download | Each file is downloaded, its size and SHA-256 checked; then `pack.json` is read and the whole pack verified; only then is it moved, in one step, into `~/Library/Application Support/HCG Animation Center/Catalog/Packs/<id>-<manifest hash>.hcgpack`. A failure leaves nothing behind. |
| Offline | A verified download is used without the network; *Add to Library* / *Apply to Desktop* copy it into the library. |
| Refresh failure | The previous catalog stays on screen (and survives restarts: `catalog-last-good.json`) with "Couldn't refresh: … Showing the catalog loaded <date>." |
| Bad items | An item that breaks the rules is skipped with a warning; the rest of the catalog still loads. Newer `formatVersion` → refused. |
| Limits | Catalog ≤ 1 MB; one item ≤ 4 GB. |

## Document

```json
{
  "format": "com.hakmicapitalgroup.animation-catalog",
  "formatVersion": 1,
  "title": "HCG Animation Catalog",
  "updated": "2026-11-21T00:00:00Z",
  "items": [
    {
      "id": "4F1C9A3E-2B7D-4E61-9C05-0D8A7B3E5F21",
      "name": "HCG Orbital Command",
      "summary": "…",
      "packFormatVersion": 1,
      "baseURL": "",
      "poster": "poster.jpg",
      "media": { "width": 3840, "height": 2160, "duration": 12 },
      "files": [
        { "file": "pack.json",  "bytes": 5905,    "sha256": "…", "role": "manifest" },
        { "file": "media.mp4",  "bytes": 3319168, "sha256": "…", "role": "media" },
        { "file": "poster.jpg", "bytes": 321060,  "sha256": "…", "role": "poster" }
      ]
    }
  ]
}
```

`id` is the pack's id; the downloaded `pack.json` must carry the same id.
