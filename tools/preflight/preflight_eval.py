"""Preflight vs the full analysis on GolfDB landmarks: do they agree on refusing?

  python tools/preflight/preflight_eval.py --golfdb golfdb/data --swingnet impact/results_swingnet.json \
      --landmarks App=lm/landmarks

Full analysis = path_fault.analyze on the 30 fps landmarks with SwingNet phases (what the app does;
labelled phases are reported too). Preflight = preflight.check on every other frame (15 fps), no
phases. Agreement = both refuse or both let it through; a full-analysis refusal the preflight lets
through counts against it whatever the reason.
Gate (PM): agreement >= 95% with automatic phases, every disagreement listed. Markdown to stdout,
exit 1 below the gate. --sweep prints every set-up frame method x refusal policy instead of gating.
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
METHODS = [("split", 0.0), ("speed", 0.0), ("mode", 0.03), ("mode", 0.05)]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--golfdb", type=Path, required=True)
    p.add_argument("--swingnet", type=Path, required=True)
    p.add_argument("--landmarks", action="append", required=True, help="Label=dir of <name>.npy")
    p.add_argument("--limit", type=int, default=400)
    p.add_argument("--step", type=int, default=2, help="keep every n-th frame for the preflight (30 fps / 2 = 15)")
    p.add_argument("--sweep", action="store_true")
    p.add_argument("--how", default="mode")
    p.add_argument("--tol", type=float, default=preflight.SETUP_TOL)
    p.add_argument("--policy", default="setup")
    a = p.parse_args()
    import pandas as pd
    df = pd.read_pickle(a.golfdb / "golfDB.pkl")
    df = df[df["view"] == "down-the-line"].head(a.limit)
    sn = {r["name"]: r.get("phases") for r in json.loads(a.swingnet.read_text(encoding="utf-8"))}
    methods = METHODS if a.sweep else [(a.how, a.tol)]
    policies = list(preflight.POLICIES) if a.sweep else [a.policy]
    failed = False
    out = [f"## 快速预检 vs 完整分析（GolfDB 沿目标线前 {a.limit} 段，预检用每 {a.step} 帧取 1 帧）", ""]
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
            sp = lm[::a.step]
            fps = 30 / a.step
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                pre = {(how, tol, pol): preflight.check(sp, fps, how=how, tol=tol, policy=pol)
                       for how, tol in methods for pol in policies}
                full = {}
                for src, ph in (("自动", sn.get(name)), ("标注", (int(ev[1]), int(ev[4]), int(ev[6])))):
                    r = analyze(lm, *ph) if ph else {"verdict": REFUSED, "reason": "没有识别出挥杆阶段"}
                    full[src] = (r["verdict"], r.get("reason", ""), r.get("camera"))
            rows.append(dict(name=name, slow=int(row.slow), pre=pre, full=full))
        n = len(rows)
        out += [f"### {label} 关键点（{n} 段）", ""]
        found = Counter(next(iter(r["pre"].values()))["swings"] for r in rows)
        out += ["初筛找到的挥杆次数（每段应为 1）：" + "，".join(f"{k} 次 {v} 段" for k, v in sorted(found.items())), ""]
        for src in ("自动", "标注"):
            by = Counter(r["full"][src][1] for r in rows if r["full"][src][0] == REFUSED)
            out += [f"完整分析（{src}阶段）拒判 {sum(by.values())} 段：" + "，".join(f"{k} {v}" for k, v in by.most_common()), ""]
        out += ["| 准备帧 | 拦截范围 | 阶段 | 一致 | 两边都拒 | 预检拒、完整给结论 | 预检放行、完整拒 |", "|---|---|---|---|---|---|---|"]
        for how, tol in methods:
            for pol in policies:
                for src in ("自动", "标注"):
                    key = (how, tol, pol)
                    both = sum(not r["pre"][key]["ok"] and r["full"][src][0] == REFUSED for r in rows)
                    pre_only = sum(not r["pre"][key]["ok"] and r["full"][src][0] != REFUSED for r in rows)
                    full_only = sum(r["pre"][key]["ok"] and r["full"][src][0] == REFUSED for r in rows)
                    agree = n - pre_only - full_only
                    ok = agree / n >= GATE
                    if src == "自动" and not a.sweep:
                        failed |= not ok
                    out.append(f"| {how}{f' {tol}' if how == 'mode' else ''} | {pol} | {src} | {agree}/{n}（{agree / n:.1%}）"
                               f"{'✅' if ok else '❌'} | {both} | {pre_only} | {full_only} |")
        out.append("")
        # the disagreement list, for the last method / policy (the configured one when not sweeping)
        for key in ([(h, t, pol) for h, t in methods for pol in policies] if a.sweep else [(a.how, a.tol, a.policy)]):
            if a.sweep and key[2] not in ("setup+tracking", "all_but_sparse"):
                continue
            out += [f"#### 不一致列表：{key[0]}{f' {key[1]}' if key[0] == 'mode' else ''} / {key[2]}（自动阶段）", "",
                    "| 段 | 慢动作 | 预检 | 完整分析 | 完整分析肩/髋宽 | 预检稀疏判定 | 稀疏肩/髋宽 |", "|---|---|---|---|---|---|---|"]
            for r in rows:
                pr, fu = r["pre"][key], r["full"]["自动"]
                if pr["ok"] == (fu[0] != REFUSED):
                    continue

                def w(c):
                    return f"{c['shoulder_width']:.2f}/{c['hip_width']:.2f}" if c else "—"
                out.append(f"| {r['name']} | {'是' if r['slow'] else ''} | {'放行' if pr['ok'] else '拒：' + pr['detail']} | "
                           f"{fu[0]} {fu[1]} | {w(fu[2])} | {pr.get('sparse_verdict', '—')} {pr.get('sparse_reason', '')} | {w(pr.get('camera'))} |")
            out.append("")
    print("\n".join(out))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
