"""Synthetic swings for the Swift parity test that hit every soft-wording state on both sides of each limit.

The GolfDB parity fixture has no swing whose camera line sits near its limit, so this adds made-up
swings (test_path_fault.make_swing, no video, no person) around each limit: offset near the outside and
inside thresholds, downswing gap just under / over its limit for a long and a short downswing, and
shoulder line just under / over the camera limit. Same format as path_parity.json; refresh_parity.py
fills in the Python verdicts.

  python tools/faults/make_synthetic_parity.py --out tools/faults/fixtures/path_parity_synthetic.json
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import path_fault as pf  # noqa: E402
from test_path_fault import make_swing  # noqa: E402


def cases():
    for loop in (-0.45, -0.4, -0.35, -0.3, 0.0, 0.25, 0.3, 0.35, 0.4):
        yield f"loop{loop:+.2f}", make_swing(loop=loop)
    for frames, gaps in ((120, (3, 4, 11, 12)), (60, (1, 2, 5, 6))):
        for gap in gaps:
            lm, a, t, i = make_swing(loop=0.0, frames=frames)
            lm[t + 2:t + 2 + gap, [pf.L_WR, pf.R_WR], 2] = 0.0
            yield f"gap{gap}_of{i - t}", (lm, a, t, i)
    for width in (0.18, 0.195, 0.205, 0.215):
        yield f"camera{width:.3f}", make_swing(loop=0.0, shoulder_width=width)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()
    out = []
    for name, (lm, ad, top, imp) in cases():
        out.append({"name": f"synthetic_{name}", "phases": [ad, top, imp],
                    "landmarks": [[[None if not math.isfinite(v) else round(float(v), 3) for v in pt] for pt in fr]
                                  for fr in lm]})
    a.out.write_text(json.dumps(out), encoding="utf-8")
    print(len(out), "swings ->", a.out)


if __name__ == "__main__":
    main()
