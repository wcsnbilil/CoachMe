"""MediaPipe pose for ClubheadDB clips, frame by frame, so the clubhead decoder can use the hands.

Runs in the MediaPipe environment (NumPy 1); the detector runs in the Ultralytics one (NumPy 2).

  python3 tools/club/clubheaddb_pose.py --frames aligned/ --clips swing_035,swing_037 --out poses/

Writes <out>/<clip>.npz with `frame` (the label frame numbers) and `landmarks` (frames x 33 x 3: pixel x, pixel y,
visibility), the same layout run_path.py caches.
"""
import argparse
import re
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
from run_path import pose_landmarks  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", required=True)
    ap.add_argument("--clips", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--model", default=str(ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task"))
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    for clip in (c for c in a.clips.split(",") if c):
        paths = sorted((Path(a.frames) / clip).glob("frame_*.jpg"))
        numbers = np.array([int(re.search(r"frame_(\d+)\.jpg$", p.name).group(1)) for p in paths])
        frames = [cv2.imread(str(p)) for p in paths]
        np.savez(out / f"{clip}.npz", frame=numbers, landmarks=pose_landmarks(frames, 30.0, Path(a.model)))
        print(clip, len(frames), flush=True)


if __name__ == "__main__":
    main()
