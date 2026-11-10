"""Preflight vs the full analysis on GolfDB landmarks: do they agree on refusing?

  python tools/preflight/preflight_eval.py --golfdb golfdb/data --swingnet impact/results_swingnet.json \
      --landmarks App=lm/landmarks

Full analysis = path_fault.analyze on all frames with SwingNet phases (what the app does; labelled
phases are reported too). Preflight = quick() on QUICK_SAMPLES poses taken from the same landmarks,
then early_setup() with the same phases. Agreement = both refuse, or both let the clip through; a
full-analysis refusal the preflight lets through counts against it whatever the reason (most are
tracking lost in the downswing, which nothing before the downswing can see).
Gate (PM): agreement >= 95% with automatic phases, every disagreement listed. Markdown to stdout,
exit 1 below the gate.
"""
from __future__ import annotations

import argparse
import json
import sys
import warnings
from collections import Counter
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import preflight  # noqa: E402
from path_fault import analyze  # noqa: E402

REFUSED = preflight.REFUSED
GATE = 0.95
FPS = 30.0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--golfdb", type=Path, required=True)
    p.add_argument("--swingnet", type=Path, required=True)
    p.add_argument("--landmarks", action="append", required=True, help="Label=dir of <name>.npy")
    p.add_argument("--limit", type=int, default=400)
    a = p.parse_args()
    import pandas as pd
    df = pd.read_pickle(a.golfdb / "golfDB.pkl")
    df = df[df["view"] == "down-the-line"].head(a.limit)
    sn = {r["name"]: r.get("phases") for r in json.loads(a.swingnet.read_text(encoding="utf-8"))}
    failed = False
    out = [f"## 快速预检 vs 完整分析（GolfDB 沿目标线前 {a.limit} 段）", "",
           f"预检 = ① 均匀抽 {preflight.QUICK_SAMPLES} 帧的快速检查 + ② 上杆顶点处按完整分析同一套规则判准备姿势 / 机位。", ""]
    for spec in a.landmarks:
        label, d = spec.split("=", 1)
        rows = []
        for row in df.itertuples():
            name = f"golfdb_{row.id}"
            npy = Path(d) / f"{name}.npy"
            if not npy.exists():
                continue
            lm = np.load(npy)
            ev = np.asarray(row.events) - row.events[0]
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                q = preflight.quick(lm[preflight.sample_indices(len(lm))], len(lm) / FPS)
                res = {}
                for src, ph in (("自动", sn.get(name)), ("标注", (int(ev[1]), int(ev[4]), int(ev[6])))):
                    full = analyze(lm, *ph) if ph else {"verdict": REFUSED, "reason": "没有识别出挥杆阶段"}
                    # no phases: the app then still runs the whole pose pass (SwingNet is retried on a person crop
                    # made from it), so the preflight has nothing to say
                    early = preflight.early_setup(lm, *ph) if ph and q["ok"] else None
                    at = preflight.early_frames(*ph) / len(lm) if ph else None
                    res[src] = dict(full=(full["verdict"], full.get("reason", "")), early=early, at=at,
                                    pre=None if q["ok"] and not early else (early or "快速检查：" + q["reason"]))
            rows.append(dict(name=name, slow=int(row.slow), quick=q, res=res))
        n = len(rows)
        out += [f"### {label} 关键点（{n} 段）", ""]
        qr = Counter(r["quick"]["reason"] for r in rows if not r["quick"]["ok"])
        w = np.array([r["quick"]["width"] for r in rows if r["quick"]["width"] is not None])
        out += [f"① 快速检查拦下 {sum(qr.values())} 段" + (f"（{'，'.join(f'{k} {v}' for k, v in qr.items())}）" if qr else "") +
                f"；最窄站姿宽度（躯干长度）中位 {np.median(w):.2f}，95% 分位 {np.percentile(w, 95):.2f}，最大 {w.max():.2f}，"
                f"阈值 {preflight.QUICK_CAMERA_WIDTH}；没有可用站姿样本 {n - len(w)} 段", ""]
        for src in ("自动", "标注"):
            rs = [r["res"][src] for r in rows]
            both = sum(x["pre"] is not None and x["full"][0] == REFUSED for x in rs)
            pre_only = [r for r in rows if r["res"][src]["pre"] is not None and r["res"][src]["full"][0] != REFUSED]
            full_only = [r for r in rows if r["res"][src]["pre"] is None and r["res"][src]["full"][0] == REFUSED]
            agree = n - len(pre_only) - len(full_only)
            ok = agree / n >= GATE
            if src == "自动":
                failed |= not ok
            at = [x["at"] for x in rs if x["pre"] and x["at"] is not None and not x["pre"].startswith("快速")]
            out += [f"**{src}阶段：一致 {agree}/{n}（{agree / n:.1%}）{'✅' if ok else '❌'}**。两边都拒 {both}；"
                    f"预检拒、完整分析给了结论 {len(pre_only)}；预检放行、完整分析拒判 {len(full_only)}"
                    f"（{'，'.join(f'{k} {v}' for k, v in Counter(r['res'][src]['full'][1] for r in full_only).most_common())}）。"
                    + (f"第 ② 层拒判时姿态只跑了全片的 {np.median(at):.0%}（中位）。" if at else ""), ""]
            out += [f"| 段 | 慢动作 | 预检 | 完整分析（{src}阶段） |", "|---|---|---|---|"]
            for r in pre_only + full_only:
                x = r["res"][src]
                out.append(f"| {r['name']} | {'是' if r['slow'] else ''} | {x['pre'] or '放行'} | {x['full'][0]} {x['full'][1]} |")
            out.append("")
    print("\n".join(out))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
