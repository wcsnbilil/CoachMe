"""Same swings, two resolutions: does the hand-path verdict survive a 160px video?

Takes hd_pipeline.py reports (HD landmarks + address/top/impact per swing), re-reads each swing
from its video, crops a square around the golfer and shrinks it to --height px (default 160x160, like GolfDB), re-runs MediaPipe on that
segment and path_fault.analyze with the same phases. Prints agreement, refusal reasons at both
resolutions, and writes <out>/res_compare.json. Low-res landmarks are cached in <out>/lowres/.

usage: python tools/faults/res_compare.py ../hd_part0 ../hd_part1 ... --out ../res160
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
from path_fault import analyze  # noqa: E402


def pose_frames(frames, fps, model):
    import mediapipe as mp
    from mediapipe.tasks import python as mpp
    from mediapipe.tasks.python import vision
    opts = vision.PoseLandmarkerOptions(base_options=mpp.BaseOptions(model_asset_path=str(model)),
                                        running_mode=vision.RunningMode.VIDEO, num_poses=1)
    out = np.full((len(frames), 33, 3), np.nan)
    with vision.PoseLandmarker.create_from_options(opts) as lm:
        for i, img in enumerate(frames):
            h, w = img.shape[:2]
            res = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(img, cv2.COLOR_BGR2RGB)),
                                      int(i * 1000 / fps))
            if res.pose_landmarks:
                out[i] = [(p.x * w, p.y * h, p.visibility) for p in res.pose_landmarks[0]]
    return out


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", type=Path, nargs="+")
    ap.add_argument("--out", type=Path, default=Path("res160"))
    ap.add_argument("--height", type=int, default=160)
    ap.add_argument("--lead", type=int, default=30, help="frames before address fed to the tracker first")
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    a = ap.parse_args()
    (a.out / "lowres").mkdir(parents=True, exist_ok=True)
    rows = []
    for rep in a.reports:
        if (rep / "results.json").exists():
            rows += json.loads((rep / "results.json").read_text(encoding="utf-8"))
    out = []
    for n, r in enumerate(rows, 1):
        ad, top, imp = r["phases"]
        lo = max(0, ad - a.lead)
        npy = a.out / "lowres" / f"{r['name']}.npy"
        if npy.exists():
            lm = np.load(npy)
        else:
            # crop a square around the golfer (from the HD landmarks of this swing) like GolfDB's
            # 160x160 clips, so the golfer is not shrunk to a few dozen pixels
            hd = np.load(r["lm"])[lo:imp + 1]
            pts = hd[..., :2][hd[..., 2] >= 0.5]
            if len(pts) < 10:
                continue
            (x0, y0), (x1, y1) = np.percentile(pts, 1, axis=0), np.percentile(pts, 99, axis=0)
            cx, cy, half = (x0 + x1) / 2, (y0 + y1) / 2, max(x1 - x0, y1 - y0) * 0.65
            cap = cv2.VideoCapture(r["video"])
            fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
            cap.set(cv2.CAP_PROP_POS_FRAMES, lo)
            frames = []
            for _ in range(lo, imp + 1):
                ok, img = cap.read()
                if not ok:
                    break
                h, w = img.shape[:2]
                xa, ya = int(max(0, cx - half)), int(max(0, cy - half))
                xb, yb = int(min(w, cx + half)), int(min(h, cy + half))
                crop = img[ya:yb, xa:xb]
                frames.append(cv2.resize(crop, (a.height, a.height), interpolation=cv2.INTER_AREA))
            cap.release()
            if len(frames) < imp - lo + 1:
                continue
            lm = pose_frames(frames, fps, a.model)
            tmp = npy.with_suffix(".tmp.npy")
            np.save(tmp, lm)
            os.replace(tmp, npy)
        low = analyze(lm, ad - lo, top - lo, imp - lo)
        rec = {"name": r["name"], "hd_verdict": r["verdict"], "hd_offset": r.get("offset"), "hd_reason": r.get("reason"),
               "low_verdict": low["verdict"], "low_offset": low.get("offset"), "low_reason": low.get("reason")}
        out.append(rec)
        print(f"{n}/{len(rows)} {r['name']}: HD {r['verdict']} {r.get('offset')} | {a.height}px {low['verdict']} {low.get('offset')}", flush=True)
    (a.out / "res_compare.json").write_text(json.dumps(out, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
    both = [o for o in out if o["hd_verdict"] != "无法判断" and o["low_verdict"] != "无法判断"]
    agree = sum(o["hd_verdict"] == o["low_verdict"] for o in both)
    print(f"\nswings {len(out)}; judged at both resolutions {len(both)}; same verdict {agree}/{len(both)}"
          + (f" = {agree / len(both):.0%}" if both else ""))
    d = [abs(o["hd_offset"] - o["low_offset"]) for o in both if o["hd_offset"] is not None and o["low_offset"] is not None]
    if d:
        print("offset |HD-low| median / p90:", round(float(np.median(d)), 3), round(float(np.percentile(d, 90)), 3))
    print("HD refusals:", dict(Counter(o["hd_reason"] for o in out if o["hd_verdict"] == "无法判断")))
    print(f"{a.height}px refusals:", dict(Counter(o["low_reason"] for o in out if o["low_verdict"] == "无法判断")))
    print("refused only at low res:", sum(o["hd_verdict"] != "无法判断" and o["low_verdict"] == "无法判断" for o in out))


if __name__ == "__main__":
    main()
