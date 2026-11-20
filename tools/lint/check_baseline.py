"""Fails when a lint baseline lists more violations than it does on the base ref.

  python3 tools/lint/check_baseline.py origin/main
"""
import json
import subprocess
import sys

BASELINES = ["tools/lint/baseline-rules.json", "tools/lint/baseline-thresholds.json"]


def count_at(ref, path):
    shown = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return len(json.loads(shown.stdout)) if shown.returncode == 0 else None


def main():
    base = sys.argv[1]
    grew = False
    for path in BASELINES:
        now = len(json.load(open(path, encoding="utf-8")))
        before = count_at(base, path)
        if before is None:
            print(f"{path}: {now}（{base} 上还没有基线）")
            continue
        print(f"{path}: {before} -> {now}")
        if now > before:
            grew = True
    if grew:
        print("基线只许变小。修掉新增的违规，不要把它记进基线。")
        sys.exit(1)


if __name__ == "__main__":
    main()
