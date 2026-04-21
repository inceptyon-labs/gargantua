---
# gargantua-5vv2
title: Strip release binaries before codesign
status: completed
type: task
priority: normal
created_at: 2026-04-20T14:51:14Z
updated_at: 2026-04-21T01:26:35Z
---

## Context

`gargantua-xuz6` lands the mlx-swift-lm SPM dep. Post-landing, the `Gargantua` release executable is 42.2 MB unstripped vs 21.7 MB stripped. `Scripts/release/*.sh` does not currently strip (grepped — no invocation). With vendored fclones + czkawka_cli at ~32 MB, an unstripped exec pushes the app bundle to ~74 MB, well over PRD §7's 35-50 MB budget. Stripped keeps us at ~54 MB, which is within a few MB of the upper bound.

## Scope

Add stripping to the release pipeline before codesigning. Two plausible shapes:

1. `strip -u -r $APP/Contents/MacOS/Gargantua` in `Scripts/release/sign.sh` as the first step before the inside-out codesign walk.
2. Pass `-Xlinker -S -Xlinker -x` to `swift build -c release` in `Scripts/release/build.sh`.

Option 1 is surgical and only affects what ships. Option 2 is cleaner but loses the unstripped artifact for local debugging of release builds. Recommend option 1.

Also strip any other executables that ride along (`GargantuaMCP` is built; confirm whether the release pipeline ships it — if yes, strip it too).

## Acceptance

- [x] Release pipeline strips `Gargantua` (and any executable shipped in `Contents/MacOS`, plus executable helpers in `Contents/Resources`) before codesign.
- [x] Release build + assemble + strip produces a `.app` whose main exec is stripped: 53,631,912 B -> 26,538,488 B (`du -sh` main exec: 25M). Full `release.sh` path verified with `--snapshot --dry-run --ci`.
- [ ] Codesign + notarize + spctl assessment still pass end-to-end after the strip step.
- [ ] App bundle total size stays under PRD §7 50 MB ceiling (without bundled models).


## Completion Notes

Implemented in commits 6a063dc and d244f24.

Files changed:
- Scripts/release/strip-binaries.sh (new strip helper for shipped Mach-O executables)
- Scripts/release/sign.sh (runs strip helper before inside-out codesign)
- Scripts/release.sh (preflights file + strip tools)
- Scripts/release/assemble-app.sh (fixes fallback placeholder iconset directory so local assemble succeeds)
- Scripts/release/README.md (documents strip-before-sign behavior)

Verification:
- Baseline and final `swift test`: 830 tests passed.
- `bash -n Scripts/release/assemble-app.sh Scripts/release/sign.sh Scripts/release/strip-binaries.sh Scripts/release.sh`: passed.
- `git diff --check`: passed.
- Synthetic strip smoke reduced copied executable 85,514,080 B -> 45,680,736 B.
- Actual release build + assemble + strip reduced main executable 53,631,912 B -> 26,538,488 B and stripped fclones + czkawka_cli before codesign.
- `./Scripts/release.sh --snapshot --dry-run --ci`: passed and shows strip commands before codesign commands.

Not fully verified locally:
- Real codesign + notarize + spctl was not run because .env.release is missing and SIGNING_IDENTITY / NOTARY_PROFILE / TEAM_ID are not exported in this environment.
- App bundle remains 60M after stripping, above the PRD §7 50M target. Filed gargantua-u6gm for bundle-size reduction; current largest files are czkawka_cli 27M, Gargantua 25M, fclones 5.1M, mlx.metallib 3.0M.
