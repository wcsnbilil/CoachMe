"""Turn a run_path.py results.json of pro swings into thresholds.

Pros do not all swing on one path: some deliberately come a little over the
top to hit a fade, others swing in-to-out for a draw. So the pros do not
define "neutral", they define the acceptable range. A swing is only flagged
when it goes further out-to-in than the pros do (slice / pull risk), or
further in-to-out (big hook / push risk).

Each golfer counts once (median of their clips), so a golfer with eight clips
does not set the range alone. --coverage picks how much of the pro spread is
accepted: 1.0 = from the most in-to-out golfer to the most out-to-in one;
0.95 trims the extreme 2.5% on each side in case one golfer is a tracking error.

  python tools/faults/calibrate.py path_fault_report/results.json --out calibration.json

Also prints the shoulder/hip line widths so the camera-angle cut-off
(--max-line-width in run_path.py) can be set by eye.
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

import numpy as np


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("results", type=Path)
    p.add_argument("--coverage", type=float, default=1.0,
                   help="share of the pro golfers' spread that counts as acceptable (1.0 = all of it)")
    p.add_argument("--out", type=Path, default=Path("calibration.json"))
    p.add_argument("--first", type=int, help="calibrate on the first N swings only, keep the rest for checking")
    a = p.parse_args()
    rows = json.loads(a.results.read_text())[: a.first]

    by_golfer = defaultdict(list)
    for r in rows:
        if "offset" in r:
            by_golfer[r.get("player") or r["name"]].append(r["offset"])
    golfer = np.array([np.median(v) for v in by_golfer.values()])
    if len(golfer) < 10:
        raise SystemExit(f"only {len(golfer)} golfers with an offset; need at least 10")
    tail = (1 - a.coverage) / 2
    lo, hi = (float(v) for v in np.quantile(golfer, [tail, 1 - tail]))
    order = sorted(by_golfer, key=lambda g: np.median(by_golfer[g]))
    cal = {"center": round(float(np.median(golfer)), 3), "outside": round(hi, 3), "inside": round(lo, 3),
           "coverage": a.coverage, "most_in_to_out": order[0], "most_out_to_in": order[-1], "golfers": len(golfer), "swings": int(sum(map(len, by_golfer.values()))),
           "source": str(a.results)}
    a.out.write_text(json.dumps(cal, ensure_ascii=False, indent=1))
    print(json.dumps(cal, ensure_ascii=False, indent=1))

    fmt = lambda g: f"{g} {np.median(by_golfer[g]):+.3f} ({len(by_golfer[g])} clips)"
    print("most in-to-out golfers:", "; ".join(fmt(g) for g in order[:5]))
    print("most out-to-in golfers:", "; ".join(fmt(g) for g in order[::-1][:5]))
    q = [0.1, 0.25, 0.5, 0.75, 0.9]
    print("golfer offset quantiles", {k: round(float(v), 3) for k, v in zip(q, np.quantile(golfer, q))})
    widths = [max(v for v in r["camera"].values() if v == v) for r in rows
              if r.get("camera") and any(v == v for v in r["camera"].values())]
    if widths:
        print("shoulder/hip line width quantiles", {k: round(float(v), 3) for k, v in zip(q, np.quantile(widths, q))},
              "-> look at the widest clips in index.html and set --max-line-width just below the off-axis ones")


if __name__ == "__main__":
    main()
