#!/usr/bin/env bash
# Fails if a file vendored from the iOS project (Packages/HCGAnimationKit/Vendor/VENDORED.md) was edited here.
set -euo pipefail
cd "$(dirname "$0")/../Packages/HCGAnimationKit"
status=0
check() {
  local actual
  actual="$( (command -v sha256sum >/dev/null && sha256sum "$1" || shasum -a 256 "$1") | cut -d' ' -f1)"
  if [ "$actual" = "$2" ]; then echo "ok        $1"; else echo "CHANGED   $1 ($actual)"; status=1; fi
}
check Sources/HCGBackgroundCore/HCGBackgroundCore.c ac415e5b5d2eb4fffd1cc21fcc4887cb37529dd890a014e00f206a6edca9dc68
check Sources/HCGBackgroundCore/include/HCGBackgroundCore.h 3c98d1eae549ef5fbdd82e7bad21991fd839e165f693397915b408689cee862b
check Vendor/hcg-background-preset-v1.schema.json 6eac9062fd3c6a694555776b15a23b1fc97e22d0eeee082b24521fa234fef3f7
check ../../schema/hcg-background-preset-v1.schema.json 6eac9062fd3c6a694555776b15a23b1fc97e22d0eeee082b24521fa234fef3f7
exit $status
