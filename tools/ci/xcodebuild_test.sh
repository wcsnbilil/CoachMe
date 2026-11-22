#!/usr/bin/env bash
# Runs an xcodebuild test command and returns as soon as the test verdict is printed.
# xcodebuild sometimes prints "** TEST ... SUCCEEDED **" and then never exits.
#
#   tools/ci/xcodebuild_test.sh xcodebuild test -workspace ... 2>&1 | tee xcodebuild.log
#
# Exit code: xcodebuild's own if it exits within GRACE seconds of the verdict;
# otherwise 0 for SUCCEEDED and 1 for FAILED.
set -u
GRACE="${XCODEBUILD_EXIT_GRACE_SECONDS:-120}"
LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

"$@" > "$LOG" 2>&1 &
PID=$!
tail -n +1 -f "$LOG" &
TAIL=$!

verdict() { grep -aoE '\*\* TEST (EXECUTE )?(SUCCEEDED|FAILED) \*\*' "$LOG" | tail -1; }

SEEN_AT=""
while kill -0 "$PID" 2>/dev/null; do
  if [ -z "$SEEN_AT" ] && [ -n "$(verdict)" ]; then SEEN_AT=$SECONDS; fi
  if [ -n "$SEEN_AT" ] && [ $((SECONDS - SEEN_AT)) -ge "$GRACE" ]; then
    echo "xcodebuild 在给出测试结论 ${GRACE} 秒后仍未退出，已结束它；结论以日志里的 TEST 行为准。" >&2
    kill "$PID" 2>/dev/null; sleep 2; kill -9 "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null
    sleep 1; kill "$TAIL" 2>/dev/null
    case "$(verdict)" in *SUCCEEDED*) exit 0 ;; *) exit 1 ;; esac
  fi
  sleep 1
done
wait "$PID"; CODE=$?
sleep 1; kill "$TAIL" 2>/dev/null
exit "$CODE"
