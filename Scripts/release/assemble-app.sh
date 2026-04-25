#!/usr/bin/env bash
# assemble-app.sh — lay out dist/Gargantua.app from swift build output.
#
# Output tree:
#   dist/Gargantua.app/
#     Contents/
#       Info.plist              (rendered from AppShell/Info.plist.in)
#       PkgInfo                 (APPL????)
#       MacOS/Gargantua         (the executable)
#       MacOS/GargantuaScheduler (LaunchAgent background scan entry point)
#       Frameworks/Sparkle.framework
#       Library/LaunchAgents/   (SMAppService per-user LaunchAgent plist)
#       Library/LaunchDaemons/  (SMAppService launch daemon plist)
#       Library/LaunchServices/ (privileged helper executable)
#       Resources/
#         AppIcon.icns          (compiled from AppShell/AppIcon.iconset)
#         Gargantua_GargantuaCore.bundle/
#           bin/fclones         (vendored helper, signing happens later)
#           bin/czkawka_cli     (vendored helper, signing happens later)
#           cleanup_rules/
#           uninstall_rules/
#
# Must run after build.sh (directly or via release.sh) so SWIFT_BIN_DIR is
# populated. If SWIFT_BIN_DIR is unset, we re-resolve it via --show-bin-path.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_env.sh
. "$_SCRIPT_DIR/_env.sh"

if [ -z "${SWIFT_BIN_DIR:-}" ]; then
    SWIFT_BIN_DIR="$(swift build \
        --package-path "$REPO_ROOT" \
        -c release \
        --arch arm64 \
        --show-bin-path)"
    export SWIFT_BIN_DIR
fi

command -v iconutil >/dev/null 2>&1 \
    || die "iconutil not found; install Xcode Command Line Tools"

log "Assembling $APP_BUNDLE..."

run rm -rf "$APP_BUNDLE"
run mkdir -p "$APP_BUNDLE/Contents/MacOS"
run mkdir -p "$APP_BUNDLE/Contents/Frameworks"
run mkdir -p "$APP_BUNDLE/Contents/Library/LaunchAgents"
run mkdir -p "$APP_BUNDLE/Contents/Library/LaunchDaemons"
run mkdir -p "$APP_BUNDLE/Contents/Library/LaunchServices"
run mkdir -p "$APP_BUNDLE/Contents/Resources"

# ----- PkgInfo --------------------------------------------------------------
# 8 bytes: "APPL" + 4-byte creator code. Generic "????" is standard for
# non-legacy apps and keeps Finder happy.
if [ "${DRY_RUN:-0}" != "1" ]; then
    printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
else
    log "DRY-RUN: write APPL???? to $APP_BUNDLE/Contents/PkgInfo"
fi

# ----- Info.plist -----------------------------------------------------------
PLIST_SRC="$APPSHELL_DIR/Info.plist.in"
PLIST_DST="$APP_BUNDLE/Contents/Info.plist"

[ -f "$PLIST_SRC" ] || die "missing Info.plist template at $PLIST_SRC"

if [ "${DRY_RUN:-0}" != "1" ]; then
    sed -e "s|@VERSION@|${VERSION}|g" \
        -e "s|@BUILD@|${BUILD}|g" \
        -e "s|@BUNDLE_ID@|${BUNDLE_ID}|g" \
        -e "s|@MACOS_MIN_VERSION@|${MACOS_MIN_VERSION}|g" \
        -e "s|@SPARKLE_FEED_URL@|${SPARKLE_FEED_URL}|g" \
        -e "s|@SPARKLE_PUBLIC_ED_KEY@|${SPARKLE_PUBLIC_ED_KEY}|g" \
        "$PLIST_SRC" > "$PLIST_DST"
    # Sanity check: no unsubstituted tokens should remain.
    # ERE because BSD grep's BRE does not treat \+ as repetition.
    if grep -qE '@[A-Z_]+@' "$PLIST_DST"; then
        die "Info.plist still has unsubstituted tokens; check $PLIST_DST"
    fi
else
    log "DRY-RUN: render $PLIST_SRC -> $PLIST_DST"
fi

# ----- Executable -----------------------------------------------------------
run cp "$SWIFT_BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
run chmod 0755 "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
run cp "$SWIFT_BIN_DIR/GargantuaScheduler" "$APP_BUNDLE/Contents/MacOS/GargantuaScheduler"
run chmod 0755 "$APP_BUNDLE/Contents/MacOS/GargantuaScheduler"

# SwiftPM links Sparkle with @rpath/Sparkle.framework and gives the CLI
# executable @loader_path as its only local rpath. App bundles conventionally
# embed frameworks under Contents/Frameworks, so add that rpath before signing.
if [ "${DRY_RUN:-0}" != "1" ]; then
    if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath '@executable_path/../Frameworks' \
            "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    fi
else
    log "DRY-RUN: install_name_tool -add_rpath @executable_path/../Frameworks $APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

# ----- Sparkle framework ----------------------------------------------------
SPARKLE_FRAMEWORK_SRC="$SWIFT_BIN_DIR/Sparkle.framework"
if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$SPARKLE_FRAMEWORK_SRC" ]; then
    die "missing Sparkle.framework at $SPARKLE_FRAMEWORK_SRC (did swift build copy binary artifacts?)"
fi
run ditto "$SPARKLE_FRAMEWORK_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

# ----- Scheduled scan LaunchAgent ------------------------------------------
SCHEDULER_PLIST_SRC="$APPSHELL_DIR/LaunchAgents/com.inceptyonlabs.gargantua.scheduler.plist.in"
SCHEDULER_PLIST_DST="$APP_BUNDLE/Contents/Library/LaunchAgents/com.inceptyonlabs.gargantua.scheduler.plist"
[ -f "$SCHEDULER_PLIST_SRC" ] || die "missing scheduler launch agent plist template at $SCHEDULER_PLIST_SRC"

if [ "${DRY_RUN:-0}" != "1" ]; then
    cp "$SCHEDULER_PLIST_SRC" "$SCHEDULER_PLIST_DST"
else
    log "DRY-RUN: copy $SCHEDULER_PLIST_SRC -> $SCHEDULER_PLIST_DST"
fi

# ----- Privileged helper ----------------------------------------------------
HELPER_EXECUTABLE="$APP_BUNDLE/Contents/Library/LaunchServices/$HELPER_BUNDLE_ID"
run cp "$SWIFT_BIN_DIR/GargantuaPrivilegedHelper" "$HELPER_EXECUTABLE"
run chmod 0755 "$HELPER_EXECUTABLE"

HELPER_PLIST_SRC="$APPSHELL_DIR/LaunchDaemons/$HELPER_BUNDLE_ID.plist.in"
HELPER_PLIST_DST="$APP_BUNDLE/Contents/Library/LaunchDaemons/$HELPER_BUNDLE_ID.plist"
[ -f "$HELPER_PLIST_SRC" ] || die "missing privileged helper plist template at $HELPER_PLIST_SRC"

if [ "${DRY_RUN:-0}" != "1" ]; then
    sed -e "s|@HELPER_BUNDLE_ID@|${HELPER_BUNDLE_ID}|g" \
        "$HELPER_PLIST_SRC" > "$HELPER_PLIST_DST"
    if grep -qE '@[A-Z_]+@' "$HELPER_PLIST_DST"; then
        die "helper launch daemon plist still has unsubstituted tokens; check $HELPER_PLIST_DST"
    fi
else
    log "DRY-RUN: render $HELPER_PLIST_SRC -> $HELPER_PLIST_DST"
fi

# ----- MLX Metal library ----------------------------------------------------
# mlx-swift via SPM CLI does not produce default.metallib — Xcode's build
# system owns .metal compilation. We produce `mlx.metallib` ourselves and
# colocate it with the executable so MLX's load_default_library picks it up
# via its first search path (see mlx/backend/metal/device.cpp).
#
# Requires the Metal Toolchain
# (`xcodebuild -downloadComponent MetalToolchain`). build-metallib.sh fails
# with a clear install hint if it's missing.
run "$SCRIPTS_DIR/build-metallib.sh" \
    --output "$APP_BUNDLE/Contents/MacOS/mlx.metallib"

# ----- Resource bundle from GargantuaCore -----------------------------------
CORE_BUNDLE_SRC="$SWIFT_BIN_DIR/Gargantua_GargantuaCore.bundle"
if [ "${DRY_RUN:-0}" != "1" ] && [ ! -d "$CORE_BUNDLE_SRC" ]; then
    die "missing $CORE_BUNDLE_SRC (did build.sh succeed?)"
fi
run cp -R "$CORE_BUNDLE_SRC" "$APP_BUNDLE/Contents/Resources/"

# ----- App icon -------------------------------------------------------------
ICONSET_SRC="$APPSHELL_DIR/AppIcon.iconset"
ICONSET_BUILD_PARENT="$(mktemp -d -t gargantua-iconset-XXXXXX)"
ICONSET_BUILD="$ICONSET_BUILD_PARENT/AppIcon.iconset"
run mkdir -p "$ICONSET_BUILD"
trap 'rm -rf "$ICONSET_BUILD_PARENT"' EXIT

REQUIRED_SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

missing=0
for spec in "${REQUIRED_SIZES[@]}"; do
    name="${spec##*:}"
    [ -f "$ICONSET_SRC/$name" ] || missing=$((missing + 1))
done

if [ "$missing" -eq 0 ]; then
    log "Using real icon PNGs from $ICONSET_SRC"
    for spec in "${REQUIRED_SIZES[@]}"; do
        name="${spec##*:}"
        run cp "$ICONSET_SRC/$name" "$ICONSET_BUILD/$name"
    done
else
    warn "$missing/${#REQUIRED_SIZES[@]} icon PNGs missing in $ICONSET_SRC"
    warn "Generating solid-color placeholder. Ship real artwork before public release."
    if [ "${DRY_RUN:-0}" != "1" ]; then
        swift "$_SCRIPT_DIR/gen-placeholder-icon.swift" 1024 "$ICONSET_BUILD/_master.png"
        for spec in "${REQUIRED_SIZES[@]}"; do
            size="${spec%%:*}"
            name="${spec##*:}"
            sips -z "$size" "$size" "$ICONSET_BUILD/_master.png" \
                --out "$ICONSET_BUILD/$name" >/dev/null
        done
        rm -f "$ICONSET_BUILD/_master.png"
    else
        log "DRY-RUN: synthesize 10 placeholder PNGs via swift + sips"
    fi
fi

run iconutil -c icns "$ICONSET_BUILD" \
    -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

log "Assembled $APP_BUNDLE"
