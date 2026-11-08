"""Export cached landmarks + the Python verdicts as one JSON for the Swift parity test.

  python tools/faults/export_parity.py report_v3b --out /tmp/path_parity.json
  COACHME_PATH_PARITY=/tmp/path_parity.json swift test --package-path CoachMeCore --filter SwingPathParityTests

Uses path_fault.analyze with its defaults, i.e. exactly what SwingPathAnalyzer
should reproduce.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from path_fault import analyze  # noqa: E402


def clean(v):
    if isinstance(v, float) and not math.isfinite(v):
        return None
    return v


def main():
    p = argparse.ArgumentParser()
    p.add_argument("report", type=Path, help="run_path.py output dir with results.json and landmarks/")
    p.add_argument("--out", type=Path, default=Path("path_parity.json"))
    p.add_argument("--limit", type=int, default=400)
    a = p.parse_args()
    rows = json.loads((a.report / "results.json").read_text(encoding="utf-8"))
    out = []
    for r in rows[: a.limit]:
        npy = a.report / "landmarks" / f"{r['name']}.npy"
        if not npy.exists() or not r.get("phases"):
            continue
        lms = np.load(npy)
        res = analyze(lms, *r["phases"])
        out.append({
            "name": r["name"],
            "phases": list(r["phases"]),
            "landmarks": [[[clean(float(v)) for v in pt] for pt in frame] for frame in lms],
            "verdict": res["verdict"],
            "offset": res.get("offset"),
            "backswing_offset": res.get("backswing_offset"),
            "loop": res.get("loop"),
            "jump_frames": res.get("jump_frames"),
        })
    a.out.write_text(json.dumps(out), encoding="utf-8")
    print(f"{len(out)} swings -> {a.out}")


if __name__ == "__main__":
    main()
