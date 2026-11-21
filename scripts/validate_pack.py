#!/usr/bin/env python3
"""Independent validator for HCG animation packs and catalogs (no Swift, no Apple frameworks).

A second implementation of the format rules, driven by the JSON Schemas in schema/, for CI and for adapter authors
(Windows, Linux, Android, web). Exit status 0 = valid.

  validate_pack.py <Pack.hcgpack> [--catalog catalog.json ...]
  validate_pack.py --catalog catalog.json
"""
import argparse
import hashlib
import json
import os
import sys
from urllib.parse import urljoin, urlparse

try:
    import jsonschema
    from referencing import Registry, Resource
except ImportError:  # pragma: no cover
    sys.exit("pip install jsonschema (4.18 or newer)")

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA_DIR = os.path.join(HERE, "..", "schema")
errors = []


def load(name):
    with open(os.path.join(SCHEMA_DIR, name)) as f:
        return json.load(f)


PRESET = load("hcg-background-preset-v1.schema.json")
PACK = load("hcg-animation-pack-v1.schema.json")
CATALOG = load("hcg-animation-catalog-v1.schema.json")
REGISTRY = Registry().with_resources([(s["$id"], Resource.from_contents(s)) for s in (PRESET, PACK, CATALOG)])


def check(cond, message):
    if not cond:
        errors.append(message)
    return cond


def schema_errors(instance, schema, where):
    v = jsonschema.Draft202012Validator(schema, registry=REGISTRY)
    for e in sorted(v.iter_errors(instance), key=lambda e: list(e.absolute_path)):
        errors.append(f"{where}: {'/'.join(map(str, e.absolute_path)) or '(root)'}: {e.message}")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest(), os.path.getsize(path)


def verify_file(folder, entry, where):
    path = os.path.join(folder, entry["file"])
    if not check(os.path.isfile(path) and not os.path.islink(path), f"{where}: {entry['file']} is missing"):
        return
    digest, size = sha256(path)
    check(size == entry["bytes"], f"{where}: {entry['file']} is {size} bytes, listed as {entry['bytes']}")
    check(digest == entry["sha256"], f"{where}: {entry['file']} does not match its sha256")


def validate_pack(folder):
    with open(os.path.join(folder, "pack.json")) as f:
        pack = json.load(f)
    schema_errors(pack, PACK, "pack.json")
    media = pack.get("media", {})
    files = {x["file"]: x for x in pack.get("files", [])}
    verify_file(folder, media, "media")
    for x in files.values():
        verify_file(folder, x, "files")
    known = ["desktop", "app-background", "banner", "loading-screen"]
    placements = pack.get("placements", {})
    for key, placement in placements.items():
        if key not in known:
            print(f"note: placement {key} is not known to version 1 readers (ignored)")
            continue
        p = placement.get("preset", {})
        schema_errors(p, PRESET, f"placements.{key}.preset")
        m = p.get("media", {})
        check(m.get("file") == media.get("file"), f"{key}: uses {m.get('file')}, the pack's clip is {media.get('file')}")
        check(m.get("width") == media.get("width") and m.get("height") == media.get("height")
              and abs(m.get("duration", -1) - media.get("duration", -2)) < 0.001, f"{key}: describes a different clip")
        check(m.get("sha256") in (None, media.get("sha256")), f"{key}: names a different media checksum")
        still = p.get("still", {}).get("file")
        check(still is None or still in files, f"{key}: still {still} is not listed in files")
        pb = p.get("playback", {})
        check(0 <= pb.get("trimStart", 0) < pb.get("trimEnd", media.get("duration", 0)) <= media.get("duration", 0) + 1e-6,
              f"{key}: trim range outside the clip")
    default = pack.get("defaultPlacement")
    check(default in placements, f"defaultPlacement {default} is not a placement")
    preset_path = os.path.join(folder, "preset.json")
    if check(os.path.isfile(preset_path), "preset.json (the default placement for HCGBackgroundKit) is missing"):
        with open(preset_path) as f:
            preset = json.load(f)
        schema_errors(preset, PRESET, "preset.json")
        check(preset == placements.get(default, {}).get("preset"), "preset.json differs from the default placement")
    print(f"pack {pack.get('name')} [{pack.get('id')}]: {len(placements)} placements, "
          f"{media.get('bytes', 0) + sum(x['bytes'] for x in files.values())} bytes")
    return pack


def validate_catalog(path, pack_folder=None, pack=None):
    with open(path) as f:
        catalog = json.load(f)
    schema_errors(catalog, CATALOG, os.path.basename(path))
    base = "file://" + os.path.abspath(path)
    for item in catalog.get("items", []):
        names = [x["file"] for x in item.get("files", [])]
        check("pack.json" in names, f"{item.get('name')}: files must include pack.json")
        check(item.get("poster") in (None, *names), f"{item.get('name')}: poster is not one of its files")
        if pack is not None and item.get("id", "").upper() == pack.get("id", "").upper() and pack_folder:
            for x in item["files"]:
                verify_file(pack_folder, x, f"catalog {os.path.basename(path)}")
        b = item.get("baseURL", "")
        if not b:
            print(f"catalog {os.path.basename(path)}: {item.get('name')} NOT HOSTED YET — fill in items[].baseURL")
            continue
        resolved = urljoin(base, b)
        scheme = urlparse(resolved).scheme
        check(scheme == "https" or (scheme == "file"), f"{item.get('name')}: baseURL must be https ({resolved})")
        if scheme == "file":
            folder = urlparse(resolved).path
            for x in item["files"]:
                verify_file(folder, x, f"catalog {os.path.basename(path)} (local files)")
        print(f"catalog {os.path.basename(path)}: {item.get('name')} -> {resolved}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("pack", nargs="?")
    ap.add_argument("--catalog", action="append", default=[])
    a = ap.parse_args()
    pack = validate_pack(a.pack) if a.pack else None
    for c in a.catalog:
        validate_catalog(c, a.pack, pack)
    if errors:
        for e in errors:
            print("ERROR", e)
        sys.exit(1)
    print("OK (python validator)")


if __name__ == "__main__":
    main()
