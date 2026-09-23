#!/bin/zsh
# Usage: scripts/test.sh [-only-testing:FANBOXClientTests/SomeTests ...]
# Runs tests on ONE shared simulator. A global lock (/tmp/fanbox-sim-lock) serializes simulator use
# across parallel worktrees (the Mac has 8 GB RAM). Waits up to ~8 minutes for the lock.
set -u
cd "$(git rev-parse --show-toplevel)"
xcodegen generate --quiet || exit 1
python3 - <<'PY' || { echo "LOCK TIMEOUT: another worktree is using the simulator; retry later"; exit 75; }
import os, time, sys
lock = "/tmp/fanbox-sim-lock"
start = time.time()
while True:
    try:
        os.mkdir(lock); sys.exit(0)
    except FileExistsError:
        try:
            if time.time() - os.path.getmtime(lock) > 900:
                os.rmdir(lock); continue
        except FileNotFoundError:
            continue
        if time.time() - start > 480: sys.exit(1)
        time.sleep(3)
PY
trap 'rmdir /tmp/fanbox-sim-lock 2>/dev/null' EXIT INT TERM
DEVICE=${SIM_DEVICE:-iPhone 17 Pro}
LOG=$(mktemp -t fanbox-test)
xcodebuild -project FANBOXClient.xcodeproj -scheme FANBOXClient \
  -destination "platform=iOS Simulator,name=$DEVICE" -jobs ${JOBS:-3} \
  COMPILER_INDEX_STORE_ENABLE=NO test "$@" > "$LOG" 2>&1
STATUS=$?
grep -E '(error|warning): ' "$LOG" | grep -E '/FANBOXClient(Tests|UITests)?/' | sort -u | head -80
grep -E "Test Case .*(failed)|error: -\[|XCTAssert|Executed [0-9]+ test|TEST (SUCCEEDED|FAILED)|\*\* TEST" "$LOG" | head -120
rm -f "$LOG"
exit $STATUS
