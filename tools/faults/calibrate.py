"""Turn a run_path.py results.json of pro swings into thresholds.

Assumption: GolfDB golfers are tour pros, so most of them should read
路径基本正常. The centre is the pro median offset (this removes the bias of
the hand-path proxy and the camera), and the band is set so that
--neutral (default 80%) of pro swings fall inside it.

  python tools/faults/calibrate.py path_fault_report/results.json --out calibration.json

Real-time and slow-motion copies of a swing, and the same golfer filmed
several times, count once per golfer so a golfer with eight clips does not
set the thresholds alone.

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
    p.add_argument("--neutral", type=float, default=0.8, help="share of pro golfers that should read neutral")
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
    center = float(np.median(golfer))
    half = float(np.quantile(np.abs(golfer - center), a.neutral))
    cal = {"center": round(center, 3), "outside": round(center + half, 3), "inside": round(center - half, 3),
           "neutral_share": a.neutral, "golfers": len(golfer), "swings": int(sum(map(len, by_golfer.values()))),
           "source": str(a.results)}
    a.out.write_text(json.dumps(cal, ensure_ascii=False, indent=1))
    print(json.dumps(cal, ensure_ascii=False, indent=1))

    q = [0.1, 0.25, 0.5, 0.75, 0.9]
    print("golfer offset quantiles", {k: round(float(v), 3) for k, v in zip(q, np.quantile(golfer, q))})
    widths = [max(v for v in r["camera"].values() if v == v) for r in rows
              if r.get("camera") and any(v == v for v in r["camera"].values())]
    if widths:
        print("shoulder/hip line width quantiles", {k: round(float(v), 3) for k, v in zip(q, np.quantile(widths, q))},
              "-> look at the widest clips in index.html and set --max-line-width just below the off-axis ones")


if __name__ == "__main__":
    main()
