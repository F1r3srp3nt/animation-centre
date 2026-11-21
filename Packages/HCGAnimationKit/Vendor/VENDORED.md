# Vendored from HCG Animation Center (iOS)

These files are copied **unmodified** from the iOS project so the Mac app, the portable pack format and the iOS tweak
share one set of rules (limits, trim/speed/still repair, fill/fit/crop geometry, GIF timing).

| File here | Source | SHA-256 |
|---|---|---|
| `Sources/HCGBackgroundCore/HCGBackgroundCore.c` | `HCGAnimationCenter/HCGBackgroundKit/Sources/HCGBackgroundKit/HCGBackgroundCore.c` | `ac415e5b5d2eb4fffd1cc21fcc4887cb37529dd890a014e00f206a6edca9dc68` |
| `Sources/HCGBackgroundCore/include/HCGBackgroundCore.h` | `HCGAnimationCenter/HCGBackgroundKit/Sources/HCGBackgroundKit/include/HCGBackgroundCore.h` | `3c98d1eae549ef5fbdd82e7bad21991fd839e165f693397915b408689cee862b` |
| `Vendor/hcg-background-preset-v1.schema.json` | `HCGAnimationCenter/HCGBackgroundKit/Schema/hcg-background-preset-v1.schema.json` | `6eac9062fd3c6a694555776b15a23b1fc97e22d0eeee082b24521fa234fef3f7` |
| `Tests/HCGAnimationPackTests/Fixtures/Aurora-preset.json` | `HCGAnimationCenter/HCGBackgroundKit/Examples/Aurora.hcgbackground/preset.json` | (test fixture) |

Repository: `F1r3srp3nt/HCG-Jailbreak-Research`, branch `claude/stoic-gates-07elp7`, commit
`35d9db7e41cc4bb706187abc3405bb635a09dbe1`.

`scripts/check-vendored.sh` (repository root) recomputes these checksums; CI fails if a vendored file is edited here.
Change the rules in the iOS project first, then copy the files again and update this table.
