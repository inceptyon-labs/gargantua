---
# gargantua-5vv2
title: Strip release binaries before codesign
status: todo
type: task
priority: normal
created_at: 2026-04-20T14:51:14Z
updated_at: 2026-04-20T14:51:14Z
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

- [ ] Release pipeline strips `Gargantua` (and `GargantuaMCP` if shipped) before codesign.
- [ ] Running `Scripts/release.sh` produces a `.app` whose main exec is stripped (`du -sh` matches the stripped number in the mlx-backend design doc within a reasonable margin).
- [ ] Codesign + notarize + spctl assessment still pass end-to-end after the strip step.
- [ ] App bundle total size stays under PRD §7 50 MB ceiling (without bundled models).
