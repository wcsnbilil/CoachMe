"""Python MediaPipe on the App's own decoded frames: separates decoding from the pose model.

  python tools/e2e/pose_on_frames.py e2e-app/frames/<clip> e2e-videos/<clip>.mp4 --out e2e-cross

The App test dumps every frame it fed MediaPipe as PNG (COACHME_E2E_DUMP_FRAMES). This script
1) compares those pixels with OpenCV's decode of the same file (decoder / colour conversion), and
2) runs Python MediaPipe (heavy, VIDEO mode, one pose, same timestamps as python_layers.py) on the
   App pixels and writes <out>/<clip>.layers.json, so layers.py can show whether the landmarks follow
   the pixels (decode differs) or the platform (MediaPipe iOS vs Python differ on equal pixels).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "e2e"))
from python_layers import decode, pose  # noqa: E402


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("frames", type=Path)
    ap.add_argument("video", type=Path)
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    ap.add_argument("--out", type=Path, default=Path("e2e-cross"))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    app = [cv2.imread(str(p), cv2.IMREAD_COLOR) for p in sorted(a.frames.glob("*.png"))]
    py, fps, stamps = decode(a.video)
    n = min(len(app), len(py))
    diffs = [float(np.abs(app[i].astype(int) - py[i].astype(int)).mean()) for i in range(n)
             if app[i].shape == py[i].shape]
    shapes = f"App {app[0].shape[1]}x{app[0].shape[0]} / OpenCV {py[0].shape[1]}x{py[0].shape[0]}"
    print(f"{a.video.stem}: {len(app)} App frames, {len(py)} OpenCV frames, {shapes}; "
          f"mean |pixel diff| {np.mean(diffs) if diffs else float('nan'):.2f}/255 (max frame {max(diffs or [0]):.2f})")
    lms = pose(app, fps, a.model)
    h, w = app[0].shape[:2]
    layers = dict(name=a.video.stem, width=w, height=h, nominalFPS=fps, timestamps=stamps[:len(app)],
                  personCounts=[1 if f else 0 for f in lms], landmarks=lms, probabilities=[], phases=None,
                  pixelDiff=float(np.mean(diffs)) if diffs else None)
    (a.out / f"{a.video.stem}.layers.json").write_text(json.dumps(layers), encoding="utf-8")


if __name__ == "__main__":
    main()
