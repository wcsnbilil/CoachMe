#!/usr/bin/env bash
# Proves check_workflows.py catches a workflow without pipefail and a step that switches shell.
set -u
cd "$(dirname "$0")"
FAILED=0
expect() {
  python3 check_workflows.py "fixtures/workflows/$2.yml" > /dev/null
  local got=$?
  if [ "$got" = "$1" ]; then echo "ok   $2"; else echo "FAIL $2: exit $got, expected $1"; FAILED=1; fi
}
expect 0 good
expect 1 no_defaults
expect 1 sh_step
exit $FAILED
