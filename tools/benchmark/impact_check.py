"""Impact frame cross-check: SwingNet vs the hands-height rule (tools/split/swing_split.py) vs hybrid.

Hybrid: when SwingNet's impact and the rule's impact differ by more than --max-gap seconds, take the
rule's; when the rule finds no swing, keep SwingNet's and flag the impact as uncertain.

  python tools/benchmark/impact_check.py --golfdb <data> --limit 400 --landmarks report_py/landmarks --out impact
  python tools/benchmark/impact_check.py --video clip.mov --landmarks-json clip.layers.json

GolfDB: each method's impact vs the label (share within 3 frames at 30 fps), how often the hybrid
replaced SwingNet, and the path verdict with automatic phases (SwingNet vs hybrid) for the P0 gates.
Writes <out>/impact.json, <out>/results_swingnet.json, <out>/results_hybrid.json (run_path.py format,
so golfdb_app_metrics.py report can score them) and prints Markdown.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "tools" / "faults"))
sys.path.insert(0, str(ROOT / "tools" / "split"))
from golfdb_eval import load_model, probabilities, read_frames  # noqa: E402
from path_fault import analyze  # noqa: E402
from person_crop import phases_from_probs  # noqa: E402
import swing_split  # noqa: E402

MAX_GAP_S = 0.1


def rule_swing(lm: np.ndarray, fps: float, near_top: int | None):
    """The rule's swing: the one whose top is closest to SwingNet's top (or the last one)."""
    sw = swing_split.find_swings(lm, fps)
    if not sw:
        return None
    if near_top is None:
        return sw[-1]
    return min(sw, key=lambda s: abs(s[1] - near_top))


def hybrid(sn, rule, fps: float, max_gap: float = MAX_GAP_S):
    """-> (phases, replaced, uncertain)"""
    if sn is None:
        return (list(rule) if rule else None), rule is not None, rule is None
    if rule is None:
        return list(sn), False, True
    if abs(rule[2] - sn[2]) > max_gap * fps:
        return [sn[0], sn[1], rule[2]], True, False
    return list(sn), False, False


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--golfdb", type=Path)
    ap.add_argument("--limit", type=int, default=400)
    ap.add_argument("--landmarks", type=Path, help="run_path.py landmark cache (<name>.npy, pixels)")
    ap.add_argument("--out", type=Path, default=Path("impact_check"))
    ap.add_argument("--max-gap", type=float, default=MAX_GAP_S)
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    import pandas as pd
    df = pd.read_pickle(a.golfdb / "golfDB.pkl")
    df = df[df["view"] == "down-the-line"].head(a.limit)
    model = load_model("numpy")
    rows, res_sn, res_hy = [], [], []
    for n, row in enumerate(df.itertuples(), 1):
        name = f"golfdb_{row.id}"
        path = a.golfdb / "videos_160" / f"{row.id}.mp4"
        npy = a.landmarks / f"{name}.npy"
        if not path.exists() or not npy.exists():
            continue
        ev = np.asarray(row.events) - row.events[0]
        label = int(ev[6])
        lm = np.load(npy)
        fps = 30.0
        sn = phases_from_probs(probabilities(model, read_frames(path)))
        rule = rule_swing(lm, fps, sn[1] if sn else None)
        hy, replaced, uncertain = hybrid(sn, rule, fps, a.max_gap)
        r = dict(name=name, label_impact=label, swingnet=sn, rule=list(rule) if rule else None, hybrid=hy,
                 replaced=replaced, uncertain=uncertain)
        rows.append(r)
        extra = {"id": int(row.id), "player": row.player, "slow": int(row.slow), "youtube_id": row.youtube_id}
        for phases, store in ((sn, res_sn), (hy, res_hy)):
            v = analyze(lm, *phases) if phases else {"verdict": "无法判断", "reason": "没有识别出挥杆阶段"}
            v = {k: x for k, x in v.items() if k not in ("hands", "ref_line")}
            v.update(name=name, phases=phases, **extra)
            store.append(v)
        if n % 50 == 0:
            print(f"{n}/{len(df)}", flush=True)
    (a.out / "impact.json").write_text(json.dumps(rows, indent=1), encoding="utf-8")
    for fn, store in (("results_swingnet.json", res_sn), ("results_hybrid.json", res_hy)):
        (a.out / fn).write_text(json.dumps(store, ensure_ascii=False, indent=1, default=float), encoding="utf-8")

    def acc(key):
        ok = [r for r in rows if r[key] is not None]
        good = sum(abs(r[key][2] - r["label_impact"]) <= 3 for r in ok)
        return good, len(rows), len(ok)
    out = [f"## 击球帧交叉核对（GolfDB {len(rows)} 段，误差 ≤3 帧 = 对）", "",
           "| 方案 | 击球帧准确 | 给出阶段的段 |", "|---|---|---|"]
    for label, key in (("SwingNet", "swingnet"), ("双手高度规则", "rule"), ("混合", "hybrid")):
        g, t, k = acc(key)
        out.append(f"| {label} | {g}/{t}（{g / t:.1%}） | {k} |")
    rep = [r for r in rows if r["replaced"]]
    rep_ok = sum(abs(r["hybrid"][2] - r["label_impact"]) <= 3 for r in rep)
    rep_was = sum(r["swingnet"] is not None and abs(r["swingnet"][2] - r["label_impact"]) <= 3 for r in rep)
    out += ["", f"- 混合方案替换了 {len(rep)} 段的击球帧：替换后对 {rep_ok} 段，替换前（SwingNet）对 {rep_was} 段",
            f"- 击球帧不确定（规则给不出）{sum(r['uncertain'] for r in rows)} 段"]
    changed = sum(x["verdict"] != y["verdict"] for x, y in zip(res_sn, res_hy))
    out.append(f"- 自动阶段下的结论变化（SwingNet → 混合）：{changed}/{len(rows)}（{changed / max(1, len(rows)):.1%}，门槛 ≤2%）")
    print("\n".join(out))


if __name__ == "__main__":
    main()
