#!/bin/zsh
# Usage: scripts/device-install.sh [--demo]
# Builds a signed Debug app for a physical iPhone and installs + launches it with devicectl.
# The iPhone must be connected (USB, or the same network after pairing) and unlocked, with Developer Mode on.
# Signing uses DEVELOPMENT_TEAM from project.yml (a wildcard team profile works for ai.nemut.FANBOXClient).
# --demo launches with the demo accounts (-demoData) so the UI can be tried without logging in.
set -eu
cd "$(git rev-parse --show-toplevel)"
xcodegen generate --quiet
LOG=$(mktemp -t fanbox-device)
if ! xcodebuild -project FANBOXClient.xcodeproj -target FANBOXClient -sdk iphoneos -configuration Debug \
     -allowProvisioningUpdates -jobs ${JOBS:-3} build SYMROOT="$PWD/build/device" > "$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20; echo "** DEVICE BUILD FAILED **"; exit 1
fi
APP="$PWD/build/device/Debug-iphoneos/FANBOXClient.app"
JSON=$(mktemp -t fanbox-devices)
xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true
DEVICE=${DEVICE:-$(python3 - "$JSON" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    devices = []
for d in devices:
    hw = d.get("hardwareProperties", {})
    if hw.get("reality") == "physical" and hw.get("platform") == "iOS":
        print(d.get("identifier", "")); break
PY
)}
if [ -z "$DEVICE" ]; then
  echo "No physical iPhone found. Connect it by USB (or pair it over the network), unlock it, and run again."
  echo "The signed app is ready at: $APP"
  exit 2
fi
xcrun devicectl device install app --device "$DEVICE" "$APP"
ARGS=()
[ "${1:-}" = "--demo" ] && ARGS=(-demoData)
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing ai.nemut.FANBOXClient "${ARGS[@]}"
