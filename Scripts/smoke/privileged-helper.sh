#!/usr/bin/env bash
# Smoke helper for the bundled SMAppService privileged uninstall daemon.

set -euo pipefail

APP_BUNDLE="${1:-dist/Gargantua.app}"
APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Gargantua"
HELPER_ID="${HELPER_BUNDLE_ID:-com.inceptyon.gargantua.privileged-helper}"

if [ ! -x "$APP_EXECUTABLE" ]; then
    echo "error: app executable not found at $APP_EXECUTABLE" >&2
    exit 1
fi

echo "==> helper status"
"$APP_EXECUTABLE" --privileged-helper-status

echo "==> helper register"
"$APP_EXECUTABLE" --privileged-helper-register

echo "==> helper status after register"
"$APP_EXECUTABLE" --privileged-helper-status

cat <<EOF

If status is requiresApproval:
  Open System Settings > General > Login Items & Extensions
  Approve Gargantua / $HELPER_ID
  Then rerun:
    "$APP_EXECUTABLE" --privileged-helper-status

Cleanup/reset commands:
  "$APP_EXECUTABLE" --privileged-helper-unregister
  sudo launchctl print system/$HELPER_ID
  sudo launchctl bootout system/$HELPER_ID 2>/dev/null || true

XPC smoke:
  mkdir -p /Applications/GargantuaPrivilegedSmoke.app/Contents/MacOS
  touch /Applications/GargantuaPrivilegedSmoke.app/Contents/MacOS/GargantuaPrivilegedSmoke
  "$APP_EXECUTABLE" --privileged-helper-smoke-trash /Applications/GargantuaPrivilegedSmoke.app

EOF
