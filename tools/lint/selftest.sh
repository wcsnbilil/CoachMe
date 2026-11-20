#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFTLINT="${SWIFTLINT:-swiftlint}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cp "$here/../../.swiftlint.yml" "$here/../../.swiftlint-thresholds.yml" "$work/"
(cd "$here/selftest" && find . -name '*.swift.txt') | while read -r f; do
  mkdir -p "$work/$(dirname "$f")"
  cp "$here/selftest/$f" "$work/${f%.txt}"
done

cd "$work"
{ "$SWIFTLINT" lint --quiet 2>/dev/null || true; "$SWIFTLINT" lint --quiet --config .swiftlint-thresholds.yml 2>/dev/null || true; } > found.txt

failed=0
while read -r file rule expected; do
  if [ "$rule" = "-" ]; then
    actual=$(grep -c "/$file:" found.txt || true)
  else
    actual=$(grep "/$file:" found.txt | grep -c "($rule)$" || true)
  fi
  if [ "$actual" = "$expected" ]; then
    echo "ok    $file $rule $actual"
  else
    echo "FAIL  $file $rule 期望 $expected 实际 $actual"; failed=1
  fi
done < "$here/selftest/expected.txt"
exit $failed
