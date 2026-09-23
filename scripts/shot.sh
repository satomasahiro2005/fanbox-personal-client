#!/bin/zsh
# Usage: scripts/shot.sh <out.png> [launch args...]
# Launches the demo app on a dedicated simulator (not the shared test simulator), waits, screenshots.
set -u
cd "$(git rev-parse --show-toplevel)"
OUT=$1; shift
DEVICE=${SHOT_DEVICE:-C9B3B3FF-A74E-4F36-BC53-9C6603B661CA}   # iPhone Air
WAIT=${SHOT_WAIT:-7}
APP=$(ls -dt ~/Library/Developer/Xcode/DerivedData/FANBOXClient-*/Build/Products/Debug-iphonesimulator/FANBOXClient.app | head -1)
xcrun simctl boot $DEVICE 2>/dev/null
xcrun simctl bootstatus $DEVICE -b >/dev/null 2>&1
xcrun simctl status_bar $DEVICE override --time "9:41" --batteryState charged --batteryLevel 100 --wifiBars 3 >/dev/null 2>&1
if [ "${SHOT_REINSTALL:-1}" = 1 ]; then xcrun simctl install $DEVICE "$APP"; fi
xcrun simctl terminate $DEVICE ai.nemut.FANBOXClient >/dev/null 2>&1
xcrun simctl launch $DEVICE ai.nemut.FANBOXClient -uiTesting -demoData "$@" >/dev/null
python3 -c "import time; time.sleep($WAIT)"
xcrun simctl io $DEVICE screenshot "$OUT" >/dev/null 2>&1 && echo "$OUT"
