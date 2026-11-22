#!/bin/bash
# Replaces one directory on the baseline-data branch with a freshly packed one, keeping the others.
#   tools/baseline/push_data.sh <packed directory> <commit message>
set -euo pipefail
source_dir="$(cd "$1" && pwd)"
message="$2"
name="$(basename "$source_dir")"
work="$(mktemp -d)"
cd "$work"
git init -q
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git remote add origin "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
if git fetch -q --depth 1 origin baseline-data; then git checkout -q -b baseline-data FETCH_HEAD; else git checkout -q --orphan baseline-data; fi
rm -rf "$name"
cp -r "$source_dir" "$name"
git add -A
if git diff --cached --quiet; then echo "$name 没有变化"; exit 0; fi
git commit -q -m "$message"
git push -q origin baseline-data
echo "已更新 baseline-data 分支的 $name"
