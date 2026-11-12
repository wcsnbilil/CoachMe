"""The app's own path on HD swings: does the camera check in the app also refuse them?

For each swing in an hd_pipeline report (whole-video landmarks not needed): cut the app's window out of
the source video (swing_split.windows: 1 s before the segment's address, 1.5 s after impact, stretched
for slow motion), run MediaPipe on the window with a fresh tracker (model input height --pose-height,
as hd_pipeline), find the phases with SwingNet on the window as the app does, then path_fault.analyze
(which walks a late address back to a still one, still_address). Reports the app's verdict and refusal
reason, and the camera widths at the frame the app measures them (address_used) and at the still-body
frame (PR #12's rule, searched only inside the window): the candidate if the app also refuses.

  python tools/camera/app_path.py <hd report dir or results.json> [...] [--names names.txt] [--limit 90]

--names: one swing name per line (e.g. the 60 + 30 swings of camera_res). Numbers only; no frames.
"""
from __future__ import annotations

import argparse
import json
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
for d in ("tools/faults", "tools/robustness", "tools/split", "tools/camera", "tools/benchmark"):
    sys.path.insert(0, str(ROOT / d))
from path_fault import MAX_LINE_WIDTH, LOW_CAMERA_MARGIN, analyze  # noqa: E402
from hd_reencode import pose, read_cut, write_lossless  # noqa: E402
from camera_res import still_frame, widths_at  # noqa: E402
import swing_split  # noqa: E402


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", type=Path, nargs="+")
    ap.add_argument("--names", type=Path)
    ap.add_argument("--limit", type=int, default=90)
    ap.add_argument("--pose-height", type=int, default=540)
    ap.add_argument("--max-frames", type=int, default=600, help="skip windows longer than this")
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    ap.add_argument("--out", type=Path, default=Path("app_path.json"))
    a = ap.parse_args()
    from run_path import swingnet_phases
    import cv2
    rows = []
    for rep in a.reports:
        f = rep / "results.json" if rep.is_dir() else rep
        if f.exists():
            rows += json.loads(f.read_text(encoding="utf-8"))
    if a.names:
        want = [x.strip() for x in a.names.read_text(encoding="utf-8-sig").split() if x.strip()]
        by = {r["name"]: r for r in rows}
        rows = [by[n] for n in want if n in by]
    rows = [r for r in rows if r.get("phases") and r.get("video")][:a.limit]
    out = []
    limit = MAX_LINE_WIDTH * (1 + LOW_CAMERA_MARGIN)
    for n, r in enumerate(rows, 1):
        ad, top, imp = r["phases"]
        cap = cv2.VideoCapture(r["video"])
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        cap.release()
        (s0, e0), = swing_split.windows([(ad, top, imp)], total, fps, single=True)
        if e0 - s0 > a.max_frames:
            print(f"{n}/{len(rows)} {r['name']}: window {e0 - s0} frames, skipped", flush=True)
            continue
        frames, _ = read_cut(r["video"], s0, e0 - 1)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "win.mkv"
            write_lossless(frames, fps, p)
            ph = swingnet_phases(p, "numpy")
        rec = {"name": r["name"], "report_reason": r.get("reason"), "window": [s0, e0], "swingnet": ph}
        if ph is None:
            rec.update(verdict="无法判断", reason="没有识别出挥杆阶段")
        else:
            lms = pose(frames, fps, a.model, a.pose_height)
            res = analyze(lms, *ph)
            used = res.get("address_used")
            still = still_frame(lms, ph[0], ph[1], ph[2])
            if still is not None and still < 0:
                still = None
            at = widths_at(lms, {"used": used, "still": still}, ph[0], ph[1], ph[2])
            rec.update(verdict=res["verdict"], reason=res.get("reason"), confidence=res.get("confidence"),
                       offset=res.get("offset"), camera=res.get("camera"), at=at,
                       split_address_in_window=ad - s0)
        out.append(rec)
        at = rec.get("at") or {}
        print(f"{n}/{len(rows)} {r['name']}: {rec['verdict']}{'（' + rec['reason'] + '）' if rec.get('reason') else ''} "
              f"swingnet={ph} split_ad={ad - s0} "
              + " ".join(f"{k}@{v['frame']}={v['widest']}" for k, v in at.items() if v), flush=True)
        a.out.write_text(json.dumps(out, ensure_ascii=False, indent=1, default=float), encoding="utf-8")

    def summary(group, title):
        if not group:
            return
        cam = sum(1 for o in group if "机位" in (o.get("reason") or ""))
        ref = sum(o["verdict"] == "无法判断" for o in group)
        still_ok = sum(1 for o in group if "机位" in (o.get("reason") or "")
                       and (o.get("at") or {}).get("still") and o["at"]["still"]["widest"] <= limit)
        print(f"| {title} | {len(group)} | {ref} | {cam} | {still_ok} |")
    print(f"\n拒判线 {limit:.3f}。最后一列：App 判机位拒判、但起杆前静止帧上宽度在线内的杆数（改用静止帧能救回的）。")
    print("| 组 | 杆数 | App 拒判 | 其中机位 | 静止帧能救回 |")
    print("|---|---|---|---|---|")
    summary([o for o in out if "机位" in (o.get("report_reason") or "")], "长跑里判机位的")
    summary([o for o in out if "机位" not in (o.get("report_reason") or "")], "长跑里其他（对照）")


if __name__ == "__main__":
    main()
