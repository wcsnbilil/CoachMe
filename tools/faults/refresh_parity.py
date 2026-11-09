"""Re-run the current Python path_fault on a committed parity fixture.

CI keeps only the landmarks (tools/faults/fixtures/path_parity.json, written once
by export_parity.py). This recomputes the Python verdicts with today's code, so
the Swift parity test always compares against the Python in the same commit:

  python tools/faults/refresh_parity.py tools/faults/fixtures/path_parity.json --out /tmp/p.json
  COACHME_PATH_PARITY=/tmp/p.json swift test --package-path CoachMeCore --filter SwingPathParityTests
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from path_fault import analyze  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument("fixture", type=Path)
    p.add_argument("--out", type=Path, required=True)
    a = p.parse_args()
    swings = json.loads(a.fixture.read_text(encoding="utf-8"))
    # Late-address copies (SwingNet's address is often late): exercise the address search too.
    late = []
    for s in swings:
        ad, top, imp = s["phases"]
        if not s["name"].endswith("_late") and top - ad >= 6:
            late.append({**s, "name": s["name"] + "_late", "phases": [ad + (top - ad) // 3, top, imp],
                         "verdict": None})
    swings = swings + late
    changed = 0
    for s in swings:
        lms = np.array([[[np.nan if v is None else v for v in pt] for pt in fr] for fr in s["landmarks"]], dtype=float)
        res = analyze(lms, *s["phases"])
        new = {
            "verdict": res["verdict"],
            "offset": res.get("offset"),
            "backswing_offset": res.get("backswing_offset"),
            "loop": res.get("loop"),
            "jump_frames": res.get("jump_frames"),
            "shoulder_width": (res.get("camera") or {}).get("shoulder_width"),
            "hip_width": (res.get("camera") or {}).get("hip_width"),
        }
        if s.get("verdict") is not None and s.get("verdict") != new["verdict"]:
            changed += 1
            print(f"{s['name']}: fixture verdict {s.get('verdict')} -> python now {new['verdict']}")
        s.update(new)
    a.out.write_text(json.dumps(swings), encoding="utf-8")
    verdicts = {}
    for s in swings:
        verdicts[s["verdict"]] = verdicts.get(s["verdict"], 0) + 1
    print(f"{len(swings)} swings, {changed} verdicts differ from the stored fixture; now {verdicts} -> {a.out}")


if __name__ == "__main__":
    main()
