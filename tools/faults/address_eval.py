"""Which address the camera check / reference line should use: GolfDB 400 comparison.

  python tools/faults/address_eval.py --golfdb golfdb/data --swingnet impact/results_swingnet.json \
      --landmarks App=report_app/landmarks --landmarks Python=report_py/landmarks --out address_eval

Modes (path_fault.analyze address_mode): still = current (SwingNet address walked back to a still
frame), camera = (a) camera check at hands_still_address, both = (b) camera check and reference line
there. Phases: GolfDB labels and SwingNet (automatic, from impact_check.py's results_swingnet.json).
Gates (PM, 2026-11-09): automatic-phase refusal <=10%, labelled-phase verdict flips vs still <=2%,
real-time vs slow-motion >=95%, held-out (from --holdout-from) over-range <=3%.
Markdown to stdout, rows to <out>/<landmarks>_<phases>_<mode>.json.
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
from compare import pair_agreement  # noqa: E402
import path_fault  # noqa: E402
from path_fault import analyze  # noqa: E402

REFUSED = "无法判断"
OVER = {"外下过度", "内下过度"}
GATE_REFUSED, GATE_FLIP, GATE_PAIR, GATE_HELD = 0.10, 0.02, 0.95, 0.03


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--golfdb", type=Path, required=True)
    p.add_argument("--swingnet", type=Path, required=True)
    p.add_argument("--landmarks", action="append", required=True, help="Label=dir of <name>.npy")
    p.add_argument("--limit", type=int, default=400)
    p.add_argument("--holdout-from", type=int, default=200)
    p.add_argument("--out", type=Path, default=Path("address_eval"))
    p.add_argument("--still", type=float, action="append", help="ADDRESS_STILL values to try (default: the module's)")
    a = p.parse_args()
    MODES = ["still"] + [f"{m}@{v:g}" for v in (a.still or [path_fault.ADDRESS_STILL]) for m in ("camera", "both")]
    a.out.mkdir(parents=True, exist_ok=True)

    import pandas as pd
    df = pd.read_pickle(a.golfdb / "golfDB.pkl")
    df = df[df["view"] == "down-the-line"].head(a.limit)
    sn = {r["name"]: r.get("phases") for r in json.loads(a.swingnet.read_text(encoding="utf-8"))}
    clips = []
    for row in df.itertuples():
        ev = np.asarray(row.events) - row.events[0]
        name = f"golfdb_{row.id}"
        clips.append((name, (int(ev[1]), int(ev[4]), int(ev[6])), sn.get(name),
                      {"id": int(row.id), "player": row.player, "slow": int(row.slow), "youtube_id": row.youtube_id}))

    out = ["## 机位检查 / 参考线用哪一帧当准备帧（GolfDB 沿目标线前 %d 段）" % a.limit, "",
           "still = 现在的做法；camera = (a) 只有机位检查用双手和肩静止的那一帧；both = (b) 机位检查和参考线都用它；@ 后是静止门槛（躯干长度）。", ""]
    verdict_rows = {}
    for spec in a.landmarks:
        label, d = spec.split("=", 1)
        d = Path(d)
        for phase_src in ("标注", "自动"):
            for mode in MODES:
                rows = []
                for name, lab, auto, extra in clips:
                    npy = d / f"{name}.npy"
                    if not npy.exists():
                        continue
                    ph = lab if phase_src == "标注" else auto
                    if not ph:
                        r = {"verdict": REFUSED, "reason": "没有识别出挥杆阶段"}
                    else:
                        with warnings.catch_warnings():
                            warnings.simplefilter("ignore")
                            m, _, v = mode.partition("@")
                            if v:
                                path_fault.ADDRESS_STILL = float(v)
                            r = analyze(np.load(npy), *ph, address_mode=m)
                        r.pop("hands", None)
                    r.update(name=name, phases=list(ph) if ph else None, label_address=lab[0], **extra)
                    rows.append(r)
                verdict_rows[(label, phase_src, mode)] = rows
                (a.out / f"{label}_{'labelled' if phase_src == '标注' else 'auto'}_{mode}.json").write_text(
                    json.dumps(rows, ensure_ascii=False, indent=1), encoding="utf-8")

        out += [f"### {label} 关键点", "",
                "| 口径 | 版本 | 拒判率 | 实时 vs 慢动作 | 留出集超范围 | 结论翻转（对 still） | 机位拒判 | 准备帧误差中位数（帧） |",
                "|---|---|---|---|---|---|---|---|"]
        passes = {}
        for phase_src in ("标注", "自动"):
            base = {r["name"]: r for r in verdict_rows[(label, phase_src, "still")]}
            for mode in MODES:
                rows = verdict_rows[(label, phase_src, mode)]
                by = {r["name"]: r for r in rows}
                n = len(rows)
                ref = sum(r["verdict"] == REFUSED for r in rows)
                ag, tot, _ = pair_agreement(by)
                held = [r for r in rows[a.holdout_from:] if r["verdict"] != REFUSED]
                ho = sum(r["verdict"] in OVER for r in held)
                flips = sum(by[k]["verdict"] != base[k]["verdict"] for k in by)
                cam = sum("机位" in r.get("reason", "") for r in rows)
                errs = [abs(r["address_used"] - r["label_address"]) for r in rows if "address_used" in r]
                med = f"{np.median(errs):.0f}" if errs else "—"
                f = lambda x, y: f"{x}/{y}（{x / y:.1%}）" if y else "—"
                out.append(f"| {phase_src}阶段 | {mode} | {f(ref, n)} | {f(ag, tot)} | {f(ho, len(held))} | "
                           f"{f(flips, n)} | {cam} | {med} |")
                ok = passes.setdefault(mode, {})
                if phase_src == "自动":
                    ok["自动阶段拒判率 ≤10%"] = n and ref / n <= GATE_REFUSED
                if phase_src == "标注":
                    ok["标注阶段结论翻转 ≤2%"] = n and flips / n <= GATE_FLIP
                ok[f"{phase_src}阶段实时 vs 慢动作 ≥95%"] = tot and ag / tot >= GATE_PAIR
                ok[f"{phase_src}阶段留出集超范围 ≤3%"] = (ho / len(held) if held else 0) <= GATE_HELD
        out += ["", "| 版本 | " + " | ".join(next(iter(passes.values())).keys()) + " | 全过 |",
                "|---|" + "---|" * (len(next(iter(passes.values()))) + 1)]
        for mode, ok in passes.items():
            out.append(f"| {mode} | " + " | ".join("✅" if v else "❌" for v in ok.values()) +
                       f" | {'✅' if all(ok.values()) else '❌'} |")
        # which clips changed under automatic phases
        base = {r["name"]: r for r in verdict_rows[(label, "自动", "still")]}
        for mode in MODES[1:]:
            ch = [(r, base[r["name"]]) for r in verdict_rows[(label, "自动", mode)]
                  if r["verdict"] != base[r["name"]]["verdict"]]
            c = Counter((b["verdict"] if b["verdict"] != REFUSED else "拒判", r["verdict"] if r["verdict"] != REFUSED else "拒判")
                        for r, b in ch)
            out += ["", f"自动阶段 {mode} 对 still 改变 {len(ch)} 段：" + "，".join(f"{x}→{y} {k}" for (x, y), k in c.most_common())]
        out.append("")
    print("\n".join(out))


if __name__ == "__main__":
    main()
