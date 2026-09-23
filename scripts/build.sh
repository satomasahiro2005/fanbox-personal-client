#!/bin/zsh
# Usage: scripts/build.sh [build|build-for-testing]
# Regenerates the Xcode project (xcodegen) and builds for the iOS Simulator.
# Prints only errors / warnings from our sources + the final status. Exit code = xcodebuild's.
set -u
cd "$(git rev-parse --show-toplevel)"
xcodegen generate --quiet || exit 1
ACTION=${1:-build}
LOG=$(mktemp -t fanbox-build)
xcodebuild -project FANBOXClient.xcodeproj -scheme FANBOXClient \
  -destination 'generic/platform=iOS Simulator' -jobs ${JOBS:-2} \
  COMPILER_INDEX_STORE_ENABLE=NO $ACTION > "$LOG" 2>&1
STATUS=$?
grep -E '(error|warning): ' "$LOG" | grep -E '/FANBOXClient(Tests|UITests)?/' | sort -u | head -${MAX_LINES:-120}
grep -E '^\*\* .* \*\*$' "$LOG" | tail -1
[ $STATUS -ne 0 ] && grep -E 'error:' "$LOG" | grep -vE '/FANBOXClient(Tests|UITests)?/' | sort -u | head -20
rm -f "$LOG"
exit $STATUS
