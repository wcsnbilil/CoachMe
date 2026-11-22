#!/usr/bin/env bash
# Checks xcodebuild_test.sh against stand-in commands: normal exit, failing exit, and a hang after the verdict.
set -u
cd "$(dirname "$0")"
export XCODEBUILD_EXIT_GRACE_SECONDS=2
FAILED=0
expect() {
  local want="$1" label="$2"; shift 2
  ./xcodebuild_test.sh bash -c "$1" > /dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then echo "ok   $label"; else echo "FAIL $label: exit $got, expected $want"; FAILED=1; fi
}
expect 0  "正常通过"           'echo "** TEST SUCCEEDED **"'
expect 65 "正常失败"           'echo "** TEST FAILED **"; exit 65'
expect 70 "编译失败（无结论）" 'echo "error: x"; exit 70'
expect 0  "通过后不退出"       'echo "** TEST EXECUTE SUCCEEDED **"; sleep 300'
expect 1  "失败后不退出"       'echo "** TEST EXECUTE FAILED **"; sleep 300'
exit $FAILED
