#!/usr/bin/env bash
# Builds Samples/OrbitalCommand.hcgpack, the ready-to-host catalog and the local catalog.
#
#   scripts/make-sample-pack.sh                     # uses the stand-in clip (rendered if missing)
#   scripts/make-sample-pack.sh --clip ~/Movies/HCG-Orbital-Command-4K.mov   # the real master
#
# Needs: ffprobe/ffmpeg (poster frame and clip numbers) and Swift (builds the hcgpack tool from Packages/HCGAnimationKit).
# The pack id and dates are fixed so the sample is reproducible; a new clip changes the checksums only.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CLIP=""
POSTER_TIME="2"
while [ $# -gt 0 ]; do
  case "$1" in
    --clip) CLIP="$2"; shift 2 ;;
    --poster-time) POSTER_TIME="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
if [ -z "$CLIP" ]; then
  CLIP="$ROOT/build/standin/orbital-command-standin-4k.mp4"
  [ -f "$CLIP" ] || { mkdir -p "$(dirname "$CLIP")"; python3 scripts/render_standin_clip.py "$CLIP"; }
fi

( cd Packages/HCGAnimationKit && swift build -c release --product hcgpack >/dev/null )
HCGPACK="$ROOT/Packages/HCGAnimationKit/.build/release/hcgpack"

probe() { ffprobe -v error -select_streams v:0 -show_entries "$1" -of default=nw=1:nk=1 "$CLIP" | head -1; }
W="$(probe stream=width)"; H="$(probe stream=height)"
ROT="$(ffprobe -v error -select_streams v:0 -show_entries stream_side_data=rotation -of default=nw=1:nk=1 "$CLIP" | head -1 || true)"
case "${ROT#-}" in 90|270) T="$W"; W="$H"; H="$T" ;; esac   # display size after rotation, as the format requires
DUR="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$CLIP")"
CODEC="$(probe stream=codec_tag_string)"
echo "clip: $CLIP  ${W}x${H}  ${DUR}s  $CODEC"

TMP="$(mktemp -d)"
ffmpeg -loglevel error -y -ss "$POSTER_TIME" -i "$CLIP" -frames:v 1 -q:v 3 "$TMP/poster.jpg"

PACK="$ROOT/Samples/OrbitalCommand.hcgpack"
"$HCGPACK" create --media "$CLIP" --name "HCG Orbital Command" --width "$W" --height "$H" --duration "$DUR" \
  --codec "$CODEC" --poster "$TMP/poster.jpg" --poster-time "$POSTER_TIME" \
  --id 4F1C9A3E-2B7D-4E61-9C05-0D8A7B3E5F21 --created 2026-11-21T00:00:00Z --out "$PACK" >/dev/null

# Placement presets: one clip, independent framing and playback per surface.
"$HCGPACK" set "$PACK" --placement desktop --scaling fill --still-time "$POSTER_TIME" --reduce-motion still --low-power still >/dev/null
"$HCGPACK" set "$PACK" --placement app-background --zoom 1 --center-x 0.5 --center-y 0.52 --reduce-motion still --low-power still >/dev/null
"$HCGPACK" set "$PACK" --placement banner --zoom 1.15 --center-x 0.5 --center-y 0.52 --speed 0.75 --reduce-motion still --low-power still >/dev/null
"$HCGPACK" set "$PACK" --placement loading-screen --scaling fit --background-color "#080C12" --speed 1.5 --reduce-motion still --low-power play >/dev/null
"$HCGPACK" set "$PACK" --placement desktop --make-default >/dev/null
"$HCGPACK" validate "$PACK"

mkdir -p catalog
"$HCGPACK" catalog --pack "$PACK" --base-url "" --title "HCG Animation Catalog" \
  --summary "Orbital command centre loop in HCG cyan. 4K, silent, seamless 12-second loop." \
  --updated 2026-11-21T00:00:00Z --out catalog/catalog.json
"$HCGPACK" catalog --pack "$PACK" --base-url "OrbitalCommand.hcgpack/" --title "HCG Animation Catalog (local)" \
  --summary "Orbital command centre loop in HCG cyan. 4K, silent, seamless 12-second loop." \
  --updated 2026-11-21T00:00:00Z --out Samples/catalog.local.json
"$HCGPACK" validate-catalog catalog/catalog.json
"$HCGPACK" validate-catalog Samples/catalog.local.json
python3 scripts/validate_pack.py "$PACK" --catalog catalog/catalog.json --catalog Samples/catalog.local.json
rm -rf "$TMP"
