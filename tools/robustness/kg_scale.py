"""Scale the downswing-gap low-confidence margin (kg) with the downswing length.

  python tools/robustness/kg_scale.py <run_path results.json (no perturbation)> [perturbed results.json ...]

The proposal fixed kg = 1 frame, which was tuned on GolfDB real-time clips (30 fps). At 60/120/240 fps
(or a slow-motion file played at 30 fps) one frame is a much smaller part of the downswing, so the
margin should be a fraction of the downswing: kg_frames = KG_FRACTION * (impact - top), where
KG_FRACTION = 1 / (median real-time downswing frames). This prints that median, then compares the
real-time and slow-motion copies of the same swing (GolfDB has both) under the fixed 1 frame and
under the scaled margin: how often the two copies give contradictory firm answers, and how often each
copy gets a soft wording. With perturbed runs it also redoes the flip-rate check with the scaled margin.
"""
from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from flip_report import SOFT, hard, state  # noqa: E402

W, MC = 0.05, 0.05


def downswing(r):
    p = r.get("phases")
    return (p[2] - p[1]) if p else None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("baseline", type=Path)
    ap.add_argument("perturbed", type=Path, nargs="*")
    a = ap.parse_args()
    rows = json.loads(a.baseline.read_text(encoding="utf-8"))
    rt = [downswing(r) for r in rows if r.get("slow") == 0 and downswing(r)]
    sl = [downswing(r) for r in rows if r.get("slow") == 1 and downswing(r)]
    med = statistics.median(rt)
    frac = 1 / med
    out = ["## 下杆缺口余量按下杆时长换算（GolfDB 实时 / 慢动作配对）", "",
           f"下杆帧数（top→impact）中位：实时 {med:g} 帧（{len(rt)} 段），慢动作 {statistics.median(sl):g} 帧（{len(sl)} 段）。"
           f"所以 kg = 1 帧（30 fps 实时）对应下杆的 **{frac:.4f}**（1/{med:g}）。", ""]

    modes = {"固定 1 帧": lambda r: 1.0,
             f"按比例 {frac:.4f} × 下杆帧数": lambda r: frac * (downswing(r) or 0),
             f"按比例，至少 1 帧": lambda r: max(1.0, frac * (downswing(r) or 0))}
    groups = defaultdict(dict)
    for r in rows:
        if "slow" in r:
            groups[(r.get("youtube_id"), r.get("player"))][r["slow"]] = r
    pairs = [(g[0], g[1]) for g in groups.values() if 0 in g and 1 in g]
    out += [f"实时 / 慢动作配对 {len(pairs)} 组（w = {W}，mc = {MC}）：", "",
            "| kg | 两份结论硬矛盾 | 实时软说法 | 慢动作软说法 | 慢动作「把握不高（下杆）」 |", "|---|---|---|---|---|"]
    for label, kg in modes.items():
        h = s0 = s1 = g1 = 0
        for r0, r1 in pairs:
            a0, a1 = state(r0, W, kg(r0), MC), state(r1, W, kg(r1), MC)
            h += hard(a0, a1)
            s0 += a0 in SOFT
            s1 += a1 in SOFT
            g1 += a1 == "low_gap"
        n = len(pairs) or 1
        out.append(f"| {label} | {100 * h / n:.1f}% | {100 * s0 / n:.1f}% | {100 * s1 / n:.1f}% | {100 * g1 / n:.1f}% |")

    if a.perturbed:
        base = {r["name"]: r for r in rows}
        out += ["", "同一套扰动下（和 flip_report 的方案模拟一样）：", "",
                "| kg | 硬翻转 | 软说法 |", "|---|---|---|"]
        runs = [{r["name"]: r for r in json.loads(p.read_text(encoding="utf-8"))} for p in a.perturbed]
        for label, kg in modes.items():
            h = s = n = 0
            for run in runs:
                for name, b in base.items():
                    p = run.get(name)
                    if p is None:
                        continue
                    sb, sp = state(b, W, kg(b), MC), state(p, W, kg(p), MC)
                    h += hard(sb, sp)
                    s += (sb in SOFT) + (sp in SOFT)
                    n += 1
            out.append(f"| {label} | {100 * h / max(n, 1):.1f}% | {100 * s / max(2 * n, 1):.1f}% |")
    print("\n".join(out))


if __name__ == "__main__":
    main()
