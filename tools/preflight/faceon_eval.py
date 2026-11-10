"""Does the quick layer stop face-on clips? (GolfDB face-on view, labelled phases)

  python tools/preflight/faceon_eval.py --golfdb golfdb/data --limit 40

Runs MediaPipe (heavy, like run_path.py) on the first --limit face-on clips; videos are read from the
local GolfDB folder and nothing is kept. Reports, per clip, the quick layer's narrowest standing
width and decision, and the full analysis's verdict with the labelled phases. Every clip should be
refused by the full analysis; the quick layer should stop most of them right away, and what it lets
through layer 2 should stop at the top of the backswing. Report only.
"""
from __future__ import annotations

import argparse
import sys
import warnings
from collections import Counter
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "tools" / "faults"))
import preflight  # noqa: E402
from path_fault import analyze  # noqa: E402
from run_path import pose_landmarks, read_video  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--golfdb", type=Path, required=True)
    p.add_argument("--limit", type=int, default=40)
    p.add_argument("--model", type=Path, default=ROOT / "CoachMe/Resources/pose_landmarker_heavy.task")
    a = p.parse_args()
    import pandas as pd
    df = pd.read_pickle(a.golfdb / "golfDB.pkl")
    df = df[df["view"] == "face-on"].head(a.limit)
    rows = []
    for row in df.itertuples():
        path = a.golfdb / "videos_160" / f"{row.id}.mp4"
        if not path.exists():
            continue
        frames, fps = read_video(path)
        lm = pose_landmarks(frames, fps, a.model)
        ev = np.asarray(row.events) - row.events[0]
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")
            q = preflight.quick(lm[preflight.sample_indices(len(lm))], len(lm) / 30.0)
            ph = (int(ev[1]), int(ev[4]), int(ev[6]))
            full = analyze(lm, *ph)
            early = preflight.early_setup(lm, *ph)
        rows.append((f"golfdb_{row.id}", q, early, full))
    n = len(rows)
    quick_stop = sum(not q["ok"] for _, q, _, _ in rows)
    either = sum((not q["ok"]) or bool(e) for _, q, e, _ in rows)
    full_ref = sum(f["verdict"] == preflight.REFUSED for *_, f in rows)
    print(f"## 正面机位（GolfDB face-on 前 {n} 段，标注阶段）\n")
    print(f"① 快速检查拦下 {quick_stop}/{n}；①+② 合计拦下 {either}/{n}；完整分析拒判 {full_ref}/{n}"
          f"（{'，'.join(f'{k} {v}' for k, v in Counter(f.get('reason', f['verdict']) for *_, f in rows).most_common())}）\n")
    print("| 段 | 最窄站姿宽度 | ① | ② | 完整分析 |\n|---|---|---|---|---|")
    for name, q, e, f in rows:
        print(f"| {name} | {q['width']} | {'拒：' + q['reason'] if not q['ok'] else '放行'} | {e or '放行'} | "
              f"{f['verdict']} {f.get('reason', '')} |")


if __name__ == "__main__":
    main()
