"""How often does a slight change to the clip flip the path verdict?

  python tools/robustness/flip_report.py <baseline results.json> <perturbed results.json> ...

Every file is tools/faults/run_path.py output on the same GolfDB clips with the
labelled phases; the perturbed runs used --perturb (re-encode, scale, crop,
brightness). Writes Markdown to stdout (CI appends it to the job summary).

Flip kinds, per (clip, perturbation):
  判定之间：both runs judged, verdicts differ (范围内 / 外下 / 内下 among each other)
  给结论 ↔ 拒判：one run judged, the other refused
  拒判原因变了：both refused for different reasons (listed, not counted as a flip)
Grouped by how far the baseline offset is from the nearest threshold.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "faults"))
from path_fault import DEFAULT_CALIBRATION  # noqa: E402

REFUSED = "无法判断"
GAP_REASON = "下杆有一段双手追踪丢失或乱跳"
CAM_REASON = "机位偏离目标线（肩/髋线太宽）"
MAX_LINE_WIDTH = 0.2
BINS = [(0.0, 0.03), (0.03, 0.06), (0.06, 0.1), (0.1, 0.2), (0.2, 9.0)]
GATE = 0.05


def margin(offset, cal=DEFAULT_CALIBRATION):
    return min(abs(offset - cal["outside"]), abs(offset - cal["inside"]))


def bin_of(r):
    if r["verdict"] == REFUSED or r.get("offset") is None:
        return "基线拒判"
    m = margin(r["offset"])
    for lo, hi in BINS:
        if lo <= m < hi:
            return f"{lo:.2f}–{hi:.2f}" if hi < 9 else f"≥{lo:.2f}"
    return "?"


def kind(b, p):
    bj, pj = b["verdict"] != REFUSED, p["verdict"] != REFUSED
    if bj and pj:
        return "same" if b["verdict"] == p["verdict"] else "judged"
    if bj != pj:
        return "refusal"
    return "same" if b.get("reason") == p.get("reason") else "reason"


def gate_ratio(r):
    """How far past (>1) or short of (<1) its refusal limit the nearest tracking gate was.
    None when the run has no gate numbers (older output, or refused before the gates)."""
    g, ratios = r.get("gates") or {}, []
    if g.get("downswing_gap_allowed"):
        ratios.append(g["downswing_gap"] / g["downswing_gap_allowed"])
    cam = [v for v in (r.get("camera") or {}).values() if isinstance(v, (int, float))]
    if cam:
        ratios.append(max(cam) / MAX_LINE_WIDTH)
    return max(ratios) if ratios else None


def _gates(r):
    g = r.get("gates") or {}
    gap = (g["downswing_gap"], g["downswing_gap_allowed"]) if g.get("downswing_gap_allowed") else None
    cam = [v for v in (r.get("camera") or {}).values() if isinstance(v, (int, float))]
    return gap, (max(cam) if cam else None)


def state(r, w, kg=0, mc=0.0, cal=DEFAULT_CALIBRATION):
    """What a user would read with
      w:  a near-boundary band of ±w torso lengths around each threshold ("edge"),
      kg: a low-confidence zone of kg frames on both sides of the downswing-gap limit ("low_gap"),
      mc: a low-confidence zone of ±mc (fraction of the limit) around the camera-line limit ("low_cam").
    Soft states are compatible with their neighbours; hard flips are firm vs firm."""
    gap, cam = _gates(r)
    if r["verdict"] == REFUSED:
        if r.get("reason") == GAP_REASON and kg and gap and gap[0] <= gap[1] + kg:
            return "low_gap"
        if r.get("reason") == CAM_REASON and mc and cam is not None and cam <= MAX_LINE_WIDTH * (1 + mc):
            return "low_cam"
        return "refused"
    if kg and gap and gap[0] > gap[1] - kg:
        return "low_gap"
    if mc and cam is not None and cam > MAX_LINE_WIDTH * (1 - mc):
        return "low_cam"
    o = r["offset"]
    if abs(o - cal["outside"]) <= w or abs(o - cal["inside"]) <= w:
        return "edge"
    return "out" if o > cal["outside"] else "in" if o < cal["inside"] else "ok"


SOFT = ("edge", "low_gap", "low_cam")
HARD_GOAL, SOFT_GOAL = 0.03, 0.15


def hard(a, b):
    return a != b and a not in SOFT and b not in SOFT


def simulate(base, runs, out):
    pairs = [(b, rows[n]) for rows in runs.values() for n, b in base.items() if n in rows]
    d = sorted(abs(p["offset"] - b["offset"]) for b, p in pairs
               if b.get("offset") is not None and p.get("offset") is not None)
    q = lambda f: d[min(len(d) - 1, int(f * len(d)))] if d else float("nan")
    out += ["", "### 扰动后 offset 变了多少（两次都给结论的）", "",
            f"{len(d)} 对：中位 {q(0.5):.3f}，90% {q(0.9):.3f}，95% {q(0.95):.3f}，99% {q(0.99):.3f}（躯干长度）。"]
    has_gates = any(r.get("gates") for r in base.values())
    rows = []
    for w in (0.0, 0.03, 0.05, 0.08, 0.1, 0.15):
        for kg in ((0, 1, 2) if has_gates else (0,)):
            for mc in ((0.0, 0.05, 0.1, 0.2) if has_gates else (0.0,)):
                hj = hr = 0
                soft = Counter()
                for b, p in pairs:
                    sb, sp = state(b, w, kg, mc), state(p, w, kg, mc)
                    soft.update(x for x in (sb, sp) if x in SOFT)
                    if hard(sb, sp):
                        hr += "refused" in (sb, sp)
                        hj += "refused" not in (sb, sp)
                n = len(pairs) or 1
                rows.append(dict(w=w, kg=kg, mc=mc, hard=(hj + hr) / n, hj=hj / n, hr=hr / n,
                                 soft=sum(soft.values()) / (2 * n), **{k: soft[k] / (2 * n) for k in SOFT}))
    frontier = [r for r in rows if not any(o["hard"] <= r["hard"] and o["soft"] <= r["soft"]
                                           and (o["hard"], o["soft"]) != (r["hard"], r["soft"]) for o in rows)]
    frontier = sorted({(r["hard"], r["soft"]): r for r in reversed(frontier)}.values(), key=lambda r: r["soft"])  # simplest setting per point
    ok = [r for r in rows if r["hard"] <= HARD_GOAL and r["soft"] <= SOFT_GOAL]
    pct = lambda x: f"{100 * x:.1f}%"
    line = lambda r: (f"| {r['w']:.2f} | {r['kg']} | {r['mc']:.2f} | {pct(r['hard'])} | {pct(r['hj'])} | {pct(r['hr'])} | "
                      f"{pct(r['soft'])} | {pct(r['edge'])} | {pct(r['low_gap'])} | {pct(r['low_cam'])} |")
    head = ["| w | kg | mc | 硬翻转 | 判定之间 | 给结论↔拒判 | 软说法合计 | 接近边界 | 把握不高（下杆缺口） | 把握不高（机位） |",
            "|---|---|---|---|---|---|---|---|---|---|"]
    out += ["", "### 方案模拟（只算用户读到的说法，不改判定）", "",
            "w = 阈值两侧「接近边界」的宽度（躯干长度）；kg = 下杆缺口限值两侧「把握不高」的帧数；"
            "mc = 机位线宽限值两侧「把握不高」的比例。硬翻转 = 两次都是确定说法且不同（范围内/外下/内下/拒判之间）；"
            "软说法占比 = 所有结果里说「接近边界」或「把握不高」的比例。"
            + ("" if has_gates else "（这批结果没有关卡数值，kg/mc 不起作用。）"), "",
            f"目标：硬翻转 ≤ {pct(HARD_GOAL)} 且软说法 ≤ {pct(SOFT_GOAL)} → "
            + (f"有 {len(ok)} 组满足，软说法最少的是 w={min(ok, key=lambda r: r['soft'])['w']:.2f}，"
               f"kg={min(ok, key=lambda r: r['soft'])['kg']}，mc={min(ok, key=lambda r: r['soft'])['mc']:.2f}。" if ok
               else "没有一组同时满足，下面是取舍曲线。"), "",
            "取舍曲线（没有别的组合能在两项上同时更好的那些）：", ""] + head + [line(r) for r in frontier]
    out += ["", "<details><summary>全部组合</summary>", ""] + head + [line(r) for r in rows] + ["", "</details>"]
    if has_gates:
        ratios = Counter()
        for b, p in pairs:
            if kind(b, p) == "refusal":
                rb, rp = gate_ratio(b), gate_ratio(p)  # noqa
                for r in (rb, rp):
                    ratios["无数值" if r is None else f"{min(r, 2.0):.1f}".replace("2.0", "≥2.0")] += 1
        out += ["", "给结论↔拒判的那些对里，两次的关卡比值（1 = 正好在限值上）："
                + "，".join(f"{k} ×{v}" for k, v in sorted(ratios.items())) + "。"]


def load(path):
    rows = json.loads(Path(path).read_text(encoding="utf-8"))
    return {r["name"]: r for r in rows}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline")
    ap.add_argument("perturbed", nargs="+")
    ap.add_argument("--json", type=Path, help="also write the per-clip flips here")
    ap.add_argument("--title", default="Python，GolfDB 沿目标线，标注阶段")
    a = ap.parse_args()
    base = load(a.baseline)
    runs = {}
    for f in a.perturbed:
        rows = load(f)
        label = next(iter(rows.values())).get("perturb") or Path(f).parent.name
        runs[label] = rows

    order = [f"{lo:.2f}–{hi:.2f}" if hi < 9 else f"≥{lo:.2f}" for lo, hi in BINS] + ["基线拒判"]
    per_bin = defaultdict(Counter)       # bin -> kind counts (all perturbations)
    per_run = defaultdict(Counter)       # perturbation -> kind counts
    clips_in_bin = Counter(bin_of(r) for r in base.values())
    detail, flipped_clips = [], defaultdict(list)
    for label, rows in runs.items():
        for name, b in base.items():
            p = rows.get(name)
            if p is None:
                continue
            k = kind(b, p)
            per_run[label][k] += 1
            per_run[label]["n"] += 1
            per_bin[bin_of(b)][k] += 1
            per_bin[bin_of(b)]["n"] += 1
            if k in ("judged", "refusal"):
                flipped_clips[name].append(label)
                detail.append({"name": name, "perturb": label, "kind": k, "base": b["verdict"], "base_offset": b.get("offset"),
                               "base_reason": b.get("reason"), "new": p["verdict"], "new_offset": p.get("offset"),
                               "new_reason": p.get("reason")})

    rate = lambda c, k: (c[k] / c["n"]) if c["n"] else 0.0
    pct = lambda x: f"{100 * x:.1f}%"
    tot = sum(per_run.values(), Counter())
    total_flip = rate(tot, "judged") + rate(tot, "refusal")
    judged = Counter(r["verdict"] for r in base.values())
    out = [f"## 轻微扰动下的结论翻转率（{a.title}）", "",
           f"基线 {len(base)} 段：" + "，".join(f"{k} {v}" for k, v in judged.most_common()) + "。"
           f"阈值 外下 > {DEFAULT_CALIBRATION['outside']}，内下 < {DEFAULT_CALIBRATION['inside']}（offset，躯干长度）。", "",
           f"**总翻转率 {pct(total_flip)}**（判定之间 {pct(rate(tot, 'judged'))} + 给结论↔拒判 {pct(rate(tot, 'refusal'))}，"
           f"共 {tot['n']} 次比较）；门槛 {pct(GATE)} → {'超过，需要方案' if total_flip > GATE else '没超过'}。"
           f"至少翻过一次的片段：{len(flipped_clips)}/{len(base)}。", "",
           "### 按扰动", "", "| 扰动 | 比较次数 | 判定之间 | 给结论↔拒判 | 合计 | 拒判原因变了 |", "|---|---|---|---|---|---|"]
    for label, c in per_run.items():
        out.append(f"| {label} | {c['n']} | {pct(rate(c, 'judged'))} | {pct(rate(c, 'refusal'))} | "
                   f"{pct(rate(c, 'judged') + rate(c, 'refusal'))} | {c['reason']} |")
    out += ["", "### 按基线 offset 离最近阈值的距离", "",
            "| 距离（躯干长度） | 片段数 | 比较次数 | 判定之间 | 给结论↔拒判 | 合计 |", "|---|---|---|---|---|---|"]
    for b in order:
        c = per_bin.get(b, Counter())
        out.append(f"| {b} | {clips_in_bin.get(b, 0)} | {c['n']} | {pct(rate(c, 'judged'))} | {pct(rate(c, 'refusal'))} | "
                   f"{pct(rate(c, 'judged') + rate(c, 'refusal'))} |")
    trans = Counter((d["base"] if d["kind"] == "judged" else (d["base"] if d["base"] != REFUSED else d["base_reason"]),
                     d["new"] if d["kind"] == "judged" else (d["new"] if d["new"] != REFUSED else d["new_reason"]))
                    for d in detail)
    out += ["", "### 翻成了什么", "", "| 原来 | 扰动后 | 次数 |", "|---|---|---|"]
    out += [f"| {x} | {y} | {n} |" for (x, y), n in trans.most_common(15)]
    simulate(base, runs, out)
    print("\n".join(out))
    if a.json:
        a.json.write_text(json.dumps(detail, ensure_ascii=False, indent=1), encoding="utf-8")


if __name__ == "__main__":
    main()
