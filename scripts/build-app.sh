#!/usr/bin/env bash
# Builds "HCG Animation Center.app" (macOS 14+, ad-hoc signed) from Apps/HCGAnimationCenter.
#
#   scripts/build-app.sh                         # this Mac's architecture, into build/
#   scripts/build-app.sh --universal             # arm64 + x86_64
#   scripts/build-app.sh --output ~/Desktop --version 0.1.0 --build 1
#
# The app bundles the sample pack (Samples/OrbitalCommand.hcgpack) and the local catalog. Nothing is published,
# notarised or installed: release stays manual.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OUT="$ROOT/build"
VERSION="0.1.0"
BUILD="1"
ARCHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --universal) ARCHS=(--arch arm64 --arch x86_64); shift ;;
    --output) OUT="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    *) echo "unknown option $1"; exit 2 ;;
  esac
done
[ "$(uname)" = "Darwin" ] || { echo "build-app.sh needs macOS (Xcode or the Command Line Tools)"; exit 1; }
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)$(git diff --quiet 2>/dev/null || echo +uncommitted)"
PKG="$ROOT/Apps/HCGAnimationCenter"

echo "== swift build (release ${ARCHS[*]:-native})"
swift build -c release --package-path "$PKG" --product HCGAnimationCenter ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release --package-path "$PKG" --product HCGAnimationCenter ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP="$OUT/HCG Animation Center.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Samples"
cp "$BIN/HCGAnimationCenter" "$APP/Contents/MacOS/HCGAnimationCenter"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__COMMIT__/$COMMIT/" "$PKG/Resources/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -R "$ROOT/Samples/OrbitalCommand.hcgpack" "$APP/Contents/Resources/Samples/"
cp "$ROOT/Samples/catalog.local.json" "$APP/Contents/Resources/Samples/"

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$PKG/Resources/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$PKG/Resources/AppIcon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

if compgen -G "$BIN/*.bundle" >/dev/null; then
  echo "warning: SwiftPM resource bundles found in $BIN (not expected; the app loads resources from Contents/Resources)"
fi

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --deep "$APP"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
echo "== built $APP"
echo "   version $VERSION ($BUILD) commit $COMMIT, $(lipo -archs "$APP/Contents/MacOS/HCGAnimationCenter")"
echo "   open it with: open \"$APP\""
