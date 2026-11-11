"""Is the camera check (shoulder / hip line width at address) calibrated for phone resolution?

MAX_LINE_WIDTH = 0.2 was set on GolfDB clips that are 160 px on the long side. On computer B, 628 of
807 HD down-the-line swings were refused as "camera off the target line" with shoulder widths of
0.20-0.43, while the overlays looked like normal down-the-line shots. This runs the same swing cut
(same frames, same phases, fresh tracker, same lead-in as hd_reencode.py) with MediaPipe fed at
different sizes and prints the camera numbers for each, so a resolution effect shows up directly.

  python tools/camera/camera_res.py <hd report dir or results.json> [...] [--limit 60]
         [--heights long160 270 540 full] [--only-reason 机位] [--out camera_res.json]

long160 = the long side shrunk to 160 px like GolfDB's videos_160; a number = model input height;
full = the source frames. Prints numbers and verdicts only; no frames are written. Temp data stays
in memory.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
sys.path.insert(0, str(ROOT / "tools" / "robustness"))
from path_fault import MAX_LINE_WIDTH, analyze  # noqa: E402
from hd_reencode import pose, read_cut  # noqa: E402


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", type=Path, nargs="+")
    ap.add_argument("--heights", nargs="+", default=["long160", "270", "540", "full"])
    ap.add_argument("--limit", type=int, default=60)
    ap.add_argument("--only-reason", default="", help="only swings whose report reason contains this (e.g. 机位)")
    ap.add_argument("--lead", type=int, default=30)
    ap.add_argument("--max-frames", type=int, default=400, help="skip swings longer than this from lead to impact")
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    ap.add_argument("--out", type=Path, default=Path("camera_res.json"))
    a = ap.parse_args()
    rows = []
    for rep in a.reports:
        f = rep / "results.json" if rep.is_dir() else rep
        if f.exists():
            rows += json.loads(f.read_text(encoding="utf-8"))
    if a.only_reason:
        rows = [r for r in rows if a.only_reason in (r.get("reason") or "")]
    rows = [r for r in rows if r.get("phases") and r.get("video")][:a.limit]
    out = []
    for n, r in enumerate(rows, 1):
        ad, top, imp = r["phases"]
        lo = max(0, ad - a.lead)
        if imp - lo + 1 > a.max_frames:
            print(f"{n}/{len(rows)} {r['name']}: {imp - lo + 1} frames, skipped", flush=True)
            continue
        frames, fps = read_cut(r["video"], lo, imp)
        if len(frames) < imp - lo + 1:
            print(f"{n}/{len(rows)} {r['name']}: cut too short, skipped", flush=True)
            continue
        h, w = frames[0].shape[:2]
        rec = {"name": r["name"], "source": [w, h], "report_reason": r.get("reason"), "by_height": {}}
        parts = []
        for v in a.heights:
            mh = h if v == "full" else int(round(h * 160 / max(h, w))) if v == "long160" else int(v)
            res = analyze(pose(frames, fps, a.model, mh), ad - lo, top - lo, imp - lo)
            cam = res.get("camera") or {}
            rec["by_height"][v] = {"model_height": mh, "verdict": res["verdict"], "reason": res.get("reason"),
                                   "offset": res.get("offset"), "confidence": res.get("confidence"),
                                   "shoulder_width": cam.get("shoulder_width"), "hip_width": cam.get("hip_width"),
                                   "address_used": res.get("address_used")}
            parts.append(f"{v}: sh {cam.get('shoulder_width')} hip {cam.get('hip_width')} {res['verdict']}"
                         f"{'（' + res['reason'] + '）' if res.get('reason') else ''}")
        out.append(rec)
        print(f"{n}/{len(rows)} {r['name']} ({w}x{h}): " + " | ".join(parts), flush=True)
        a.out.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")

    print(f"\n{len(out)} swings. Camera limit {MAX_LINE_WIDTH} (refused above {MAX_LINE_WIDTH * 1.05:.3f}).")
    print("| input | median shoulder | median hip | wider of the two > limit | refused (any reason) | judged |")
    print("|---|---|---|---|---|---|")
    for v in a.heights:
        bh = [o["by_height"][v] for o in out if v in o["by_height"]]
        sh = [b["shoulder_width"] for b in bh if isinstance(b["shoulder_width"], (int, float))]
        hp = [b["hip_width"] for b in bh if isinstance(b["hip_width"], (int, float))]
        wide = sum(1 for b in bh if max([x for x in (b["shoulder_width"], b["hip_width"]) if isinstance(x, (int, float))],
                                         default=0) > MAX_LINE_WIDTH * 1.05)
        ref = sum(b["verdict"] == "无法判断" for b in bh)
        print(f"| {v} | {np.median(sh) if sh else float('nan'):.3f} | {np.median(hp) if hp else float('nan'):.3f} | "
              f"{wide}/{len(bh)} | {ref}/{len(bh)} | {len(bh) - ref}/{len(bh)} |")


if __name__ == "__main__":
    main()
