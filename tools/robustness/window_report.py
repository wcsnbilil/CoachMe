"""Report for window_crop.py: how often cutting the swing out of the clip changes what the user reads.

  python tools/robustness/window_report.py whole.json app.json [split.json lead0.5.json ...] [--title ...]

For each variant vs the whole clip: flips over all clips and over the clips that were really cut,
split into judged<->judged and judged<->refused, plus the hard flips as the app now words them
(soft wordings from the `confidence` field never count as hard). Then how far the cut's tracker is
from the whole clip's, by frames since the cut's first frame (tracker warm-up), and the flipped clips.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np

REFUSED = "无法判断"
GOAL = 0.02


def firm(r):
    """What the user reads, firm or soft: 'soft', a refusal reason, or the verdict."""
    if r["verdict"] == REFUSED:
        return "拒判：" + r.get("reason", "")
    if r.get("confidence", "normal") != "normal":
        return "soft"
    return r["verdict"]


def pct(x, n):
    return f"{100 * x / n:.1f}%" if n else "—"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("whole", type=Path)
    ap.add_argument("variants", type=Path, nargs="+")
    ap.add_argument("--title", default="裁出单杆窗口再分析 vs 整段分析（GolfDB 沿目标线，标注阶段）")
    a = ap.parse_args()
    base = {r["name"]: r for r in json.loads(a.whole.read_text(encoding="utf-8"))}
    out = [f"## {a.title}", "",
           f"基线（整段）{len(base)} 段，其中拒判 {sum(r['verdict'] == REFUSED for r in base.values())}。"
           f"门槛：裁切造成的硬翻转 ≤ {GOAL:.0%}。硬翻转 = 两次都是确定的说法（结论或拒判，不含软说法）且不同。", "",
           "| 窗口 | 比较 | 真的裁了 | 判定之间 | 给结论↔拒判 | 合计 | 硬翻转（现在的说法） | 只看裁了的：合计 | 只看裁了的：硬翻转 |",
           "|---|---|---|---|---|---|---|---|---|"]
    flipped, warm = [], {}
    for p in a.variants:
        if not p.exists():
            out.append(f"| {p.stem} | 没有结果（这个 job 失败了） | | | | | | | |")
            continue
        rows = [r for r in json.loads(p.read_text(encoding="utf-8")) if r["verdict"] != "skip" and r["name"] in base]
        if not rows:
            continue
        v = rows[0]["perturb"]
        n = len(rows)
        cut = [r for r in rows if r.get("cut")]
        jj = jr = hard = cj = ch = 0
        for r in rows:
            b = base[r["name"]]
            br, rr = b["verdict"] == REFUSED, r["verdict"] == REFUSED
            changed = b["verdict"] != r["verdict"] if not (br and rr) else False
            if changed:
                if br or rr:
                    jr += 1
                else:
                    jj += 1
            fb, fr = firm(b), firm(r)
            h = fb != fr and "soft" not in (fb, fr)
            hard += h
            if r.get("cut"):
                cj += changed
                ch += h
            if changed or h:
                flipped.append((v, r, b, h))
        skipped = sum(1 for r in json.loads(p.read_text(encoding="utf-8")) if r["verdict"] == "skip")
        out.append(f"| {v} | {n}{f'（另 {skipped} 段窗口没包住标注挥杆）' if skipped else ''} | {len(cut)} | {pct(jj, n)} | "
                   f"{pct(jr, n)} | {pct(jj + jr, n)} | **{pct(hard, n)}** | {pct(cj, len(cut))} | {pct(ch, len(cut))} |")
        for r in cut:
            t = r.get("torso_px_whole") or base[r["name"]].get("torso_px")
            if not t or not r.get("warm"):
                continue
            for i, d in enumerate(r["warm"]):
                if d is not None:
                    warm.setdefault(v, {}).setdefault(min(i // 5, 6), []).append(d / t)
    if warm:
        labels = ["0–4", "5–9", "10–14", "15–19", "20–24", "25–29", "30+"]
        out += ["", "### 裁切后追踪和整段差多少（双手中点、两肩中点中较大的那个，躯干长度）", "",
                "按「离裁切起点第几帧」分组：中位 / 90% / 99%。差值如果在开头大、后面变小，就是追踪器需要预热。", "",
                "| 窗口 | " + " | ".join(f"第 {x} 帧" for x in labels) + " |", "|---|" + "---|" * len(labels)]
        for v, bins in warm.items():
            cells = []
            for i in range(len(labels)):
                d = bins.get(i)
                cells.append(f"{np.median(d):.3f} / {np.quantile(d, .9):.3f} / {np.quantile(d, .99):.3f}" if d else "—")
            out.append(f"| {v} | " + " | ".join(cells) + " |")
    if flipped:
        out += ["", "### 变了的片段", "",
                "| 窗口 | 片段 | 慢动作 | 窗口 | 准备帧离裁切起点 | 整段 | 裁切后 | offset 变化 | 硬翻转 |", "|---|---|---|---|---|---|---|---|---|"]
        for v, r, b, h in sorted(flipped, key=lambda x: (x[0], x[1]["name"])):
            lead = r["phases"][0] - r["window"][0] if r.get("window") else None
            do = (f"{r['offset'] - b['offset']:+.3f}" if isinstance(r.get("offset"), (int, float))
                  and isinstance(b.get("offset"), (int, float)) else "")
            desc = lambda x: x["verdict"] + (f"（{x.get('reason', '')}）" if x["verdict"] == REFUSED else
                                             f" {x.get('offset')} {x.get('confidence', '')}")
            out.append(f"| {v} | {r['name']} | {'是' if r.get('slow') else ''} | {r.get('window')} / {r.get('frames')} 帧 | "
                       f"{lead} | {desc(b)} | {desc(r)} | {do} | {'是' if h else ''} |")
    print("\n".join(out))


if __name__ == "__main__":
    main()
