"""Cases for the Swift preflight parity test (COACHME_PREFLIGHT_PARITY).

From the GolfDB fixture clips (tools/faults/fixtures/path_parity.json), as is and altered so every
branch is hit: shoulders / hips spread (camera off the line), wrists hidden over the backswing,
trunk hidden, frames cut (duration), poses blanked (no person). Each case carries the quick-layer
samples' decision and the early set-up refusal with the fixture's phases.

  python tools/preflight/make_preflight_parity.py tools/faults/fixtures/path_parity.json --out /tmp/pre.json
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

# Python reason -> SwingPathAnalyzer.Refusal raw value
REFUSAL = {"阶段顺序不对": "phaseOrder", "准备姿势躯干不可见": "torsoNotVisible", "手腕可见帧太少": "wristsNotVisible",
           "关键点跳动太多": "trackingJumps", "机位偏离目标线（肩/髋线太宽）": "cameraOffAxis"}


def load(path: Path) -> list[dict]:
    out = json.loads(path.read_text(encoding="utf-8"))
    for s in out:
        s["lm"] = np.array([[[np.nan if v is None else v for v in pt] for pt in fr] for fr in s["landmarks"]], float)
    return out


def variants(s: dict):
    lm, (ad, top, imp) = s["lm"], s["phases"]
    yield "as_is", lm
    for f in (1.6, 2.5, 6.0):  # spread shoulders and hips sideways around their middle
        a = lm.copy()
        for l, r in ((11, 12), (23, 24)):
            mid = (a[:, l, 0] + a[:, r, 0]) / 2
            a[:, l, 0] = mid + (a[:, l, 0] - mid) * f
            a[:, r, 0] = mid + (a[:, r, 0] - mid) * f
        yield f"spread{f}", a
    a = lm.copy(); a[ad:top, [15, 16], 2] = 0.1
    yield "wrists_hidden", a
    a = lm.copy(); a[max(0, ad - 10):ad + 10, [11, 12, 23, 24], 2] = 0.1
    yield "trunk_hidden_at_address", a
    a = lm.copy(); a[:, [11, 12, 23, 24], 2] = 0.1
    yield "trunk_hidden", a
    a = lm.copy(); a[::2, :, :] = np.nan
    a[1::4, :, :] = np.nan
    yield "mostly_no_pose", a
    yield "short", lm[:20]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("fixture", type=Path)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    rows, tally = [], Counter()
    for s in load(a.fixture):
        for tag, lm in variants(s):
            lm = np.where(np.isfinite(lm), np.round(lm, 3), np.nan)
            idx = preflight.sample_indices(len(lm))
            duration = len(lm) / 30.0
            with warnings.catch_warnings():
                warnings.simplefilter("ignore")
                q = preflight.quick(lm[idx], duration)
                ph = s["phases"]
                early = preflight.early_setup(lm, *ph) if ph[2] < len(lm) else None
            tally[(tag, q["reason"] or "ok", REFUSAL.get(early, early) or "ok")] += 1
            rows.append(dict(name=f"{s['name']}_{tag}", duration=duration, samples=idx, phases=ph,
                             quick=q["reason"], width=q["width"],
                             early=REFUSAL[early] if early else None,
                             early_frames=preflight.early_frames(*ph),
                             landmarks=[[[None if not np.isfinite(v) else float(v) for v in pt] for pt in fr] for fr in lm]))
    a.out.write_text(json.dumps(rows), encoding="utf-8")
    for k, v in sorted(tally.items()):
        print(f"{k[0]:24s} quick={k[1]:8s} early={k[2]:16s} {v}")


if __name__ == "__main__":
    main()
