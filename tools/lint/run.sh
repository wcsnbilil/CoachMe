#!/bin/bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
SWIFTLINT="${SWIFTLINT:-swiftlint}"
RULES=tools/lint/baseline-rules.json
THRESHOLDS=tools/lint/baseline-thresholds.json

pretty() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); json.dump(d,open(p,"w"),ensure_ascii=False,indent=1,sort_keys=True); open(p,"a").write("\n")' "$1"; }

if [ "${1:-}" = "--update-baseline" ]; then
  "$SWIFTLINT" lint --quiet --write-baseline "$RULES" >/dev/null
  "$SWIFTLINT" lint --quiet --config .swiftlint-thresholds.yml --write-baseline "$THRESHOLDS" >/dev/null
  pretty "$RULES"; pretty "$THRESHOLDS"
  echo "基线已更新：$RULES、$THRESHOLDS"
  exit 0
fi

status=0
"$SWIFTLINT" lint --quiet --strict --baseline "$RULES" || status=1
if ! "$SWIFTLINT" lint --quiet --strict --config .swiftlint-thresholds.yml --baseline "$THRESHOLDS"; then
  status=1
  echo
  echo "阈值不能写成字面量：把这个数加进阈值配置并起一个说明含义的名字，Swift 和 Python 都从配置读。"
fi
exit $status
