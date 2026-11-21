#!/usr/bin/env bash
# Fails if docs/COMPATIBILITY.md's generated table differs from `hcgpack compatibility`.
set -euo pipefail
cd "$(dirname "$0")/.."
HCGPACK="${HCGPACK:-Packages/HCGAnimationKit/.build/release/hcgpack}"
expected="$("$HCGPACK" compatibility)"
actual="$(sed -n '/BEGIN GENERATED: hcgpack compatibility/,/END GENERATED/p' docs/COMPATIBILITY.md | sed '1d;$d')"
if [ "$expected" != "$actual" ]; then
  echo "docs/COMPATIBILITY.md is out of date; regenerate the table with: hcgpack compatibility"
  diff <(echo "$expected") <(echo "$actual") || true
  exit 1
fi
echo "docs/COMPATIBILITY.md matches PlatformSupport.matrix"
