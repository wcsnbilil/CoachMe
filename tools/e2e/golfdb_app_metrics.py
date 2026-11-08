"""App-pipeline baseline on GolfDB: the three P0 numbers for App landmarks next to Python's.

  # 1. App landmarks (GolfDBAppPipelineTests JSON) -> run_path.py landmark cache, then run_path with it
  python tools/e2e/golfdb_app_metrics.py cache golfdb-app report_app
  python tools/faults/run_path.py --golfdb <data> --limit 400 --out report_app
  # 2. numbers, App vs Python (Python = run_path.py on its own MediaPipe landmarks)
  python tools/e2e/golfdb_app_metrics.py report report_app/results.json report_py/results.json --holdout-from 200

Numbers per side: verdict counts, refusal rate, real-time vs slow-motion agreement (same swing,
GolfDB's two copies), held-out over-range rate (clips after the first --holdout-from, which the
thresholds were not tuned on), plus per-clip App vs Python verdict agreement. Markdown to stdout.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
from compare import pair_agreement  # noqa: E402

OVER = {"外下过度", "内下过度"}


def cache(app_dir: Path, report: Path):
    out = report / "landmarks"
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for f in sorted(app_dir.glob("*.json")):
        d = json.loads(f.read_text())
        arr = np.full((len(d["landmarks"]), 33, 3), np.nan)
        for i, fr in enumerate(d["landmarks"]):
            if len(fr) == 33:
                a = np.array(fr, float)
                arr[i] = np.c_[a[:, 0] * d["width"], a[:, 1] * d["height"], a[:, 2]]
        np.save(out / f"{d['name']}.npy", arr)
        n += 1
    print(f"{n} App landmark files -> {out}")


def numbers(rows: list[dict], holdout_from: int) -> dict:
    by = {r["name"]: r for r in rows}
    c = Counter(r["verdict"] for r in rows)
    agree, total, _ = pair_agreement(by)
    held = rows[holdout_from:]
    held_judged = [r for r in held if r["verdict"] != "无法判断"]
    return dict(n=len(rows), counts=c, refused=c.get("无法判断", 0), pair=(agree, total),
                held=(sum(r["verdict"] in OVER for r in held_judged), len(held_judged)))


def report(app_path: Path, py_path: Path | None, holdout_from: int):
    app = json.loads(app_path.read_text(encoding="utf-8"))
    py = json.loads(py_path.read_text(encoding="utf-8")) if py_path and py_path.exists() else None
    if py:  # same clips on both sides (the App run may stop early on a slow runner)
        names = {r["name"] for r in app}
        py = [r for r in py if r["name"] in names]
    sides = [("App 流水线", numbers(app, holdout_from))] + ([("Python", numbers(py, holdout_from))] if py else [])
    pct = lambda a, b: f"{a}/{b}（{a / b:.1%}）" if b else "—"
    out = [f"## GolfDB 上的 App 流水线基准（{len(app)} 段，阶段用 GolfDB 标注）", "",
           "| | " + " | ".join(s for s, _ in sides) + " |", "|---|" + "---|" * len(sides)]
    out.append("| 职业范围 / 外下过度 / 内下过度 / 拒判 | " + " | ".join(
        f"{m['counts'].get('路径在职业范围内', 0)} / {m['counts'].get('外下过度', 0)} / "
        f"{m['counts'].get('内下过度', 0)} / {m['refused']}" for _, m in sides) + " |")
    out.append("| 拒判率 | " + " | ".join(pct(m["refused"], m["n"]) for _, m in sides) + " |")
    out.append("| 实时 vs 慢动作一致 | " + " | ".join(pct(*m["pair"]) for _, m in sides) + " |")
    out.append(f"| 留出集（第 {holdout_from + 1} 段起）超范围 | " + " | ".join(pct(*m["held"]) for _, m in sides) + " |")
    if py:
        pb = {r["name"]: r for r in py}
        both = [(r, pb[r["name"]]) for r in app if r["name"] in pb]
        same = sum(a["verdict"] == p["verdict"] for a, p in both)
        out += ["", f"逐段结论 App = Python：{pct(same, len(both))}", ""]
        trans = Counter((p["verdict"], a["verdict"]) for a, p in both if a["verdict"] != p["verdict"])
        out += ["| Python → App | 段数 |", "|---|---|"] + [f"| {p} → {a} | {k} |" for (p, a), k in trans.most_common()]
    print("\n".join(out))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("cache")
    c.add_argument("app_dir", type=Path)
    c.add_argument("report", type=Path)
    r = sub.add_parser("report")
    r.add_argument("app_results", type=Path)
    r.add_argument("py_results", type=Path, nargs="?")
    r.add_argument("--holdout-from", type=int, default=200)
    a = ap.parse_args()
    if a.cmd == "cache":
        cache(a.app_dir, a.report)
    else:
        report(a.app_results, a.py_results, a.holdout_from)


if __name__ == "__main__":
    main()
