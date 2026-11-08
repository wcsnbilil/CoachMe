"""Python side of the whole chain, keeping every layer for tools/e2e/layers.py.

  python tools/e2e/python_layers.py e2e-videos/*.mp4 --out e2e-python

For each video: OpenCV decode (size, fps, timestamps) -> MediaPipe heavy (VIDEO mode, one pose,
timestamps i*1000/fps, exactly as run_path.py) -> SwingNet (NumPy port, 64-frame chunks) ->
path_fault.analyze. Writes <out>/<name>.layers.json (same keys as the App's) and <out>/results.json
in run_path.py's format for compare.py.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
sys.path.insert(0, str(ROOT / "tools" / "benchmark"))
from path_fault import analyze  # noqa: E402


def r4(v: float) -> float:
    return round(float(v), 4)


def decode(path: Path):
    cap = cv2.VideoCapture(str(path))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    frames, stamps = [], []
    while True:
        ok, img = cap.read()
        if not ok:
            break
        stamps.append(cap.get(cv2.CAP_PROP_POS_MSEC) / 1000)
        frames.append(img)
    cap.release()
    return frames, fps, stamps


def pose(frames, fps, model: Path) -> list[list[list[float]]]:
    import mediapipe as mp
    from mediapipe.tasks import python as mpp
    from mediapipe.tasks.python import vision
    opts = vision.PoseLandmarkerOptions(base_options=mpp.BaseOptions(model_asset_path=str(model)),
                                        running_mode=vision.RunningMode.VIDEO, num_poses=1)
    out = []
    with vision.PoseLandmarker.create_from_options(opts) as lm:
        for i, img in enumerate(frames):
            res = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB,
                                               data=cv2.cvtColor(img, cv2.COLOR_BGR2RGB)), int(i * 1000 / fps))
            out.append([[r4(p.x), r4(p.y), r4(p.visibility)] for p in res.pose_landmarks[0]]
                       if res.pose_landmarks else [])
    return out


def swingnet(path: Path):
    from golfdb_eval import load_model, probabilities, read_frames
    from app_selector import SwingNetEventSelector
    probs = probabilities(load_model("numpy"), read_frames(path))
    sel = SwingNetEventSelector()
    for t, row in enumerate(probs):
        sel.append(list(map(float, row)), float(t))
    marks = sel.keyframes()
    phases = None if not marks else [int(marks["address"][0]), int(marks["top"][0]), int(marks["impact"][0])]
    return [[r4(v) for v in row] for row in probs], phases


def pixels(landmarks, w: float, h: float) -> np.ndarray:
    out = np.full((len(landmarks), 33, 3), np.nan)
    for i, fr in enumerate(landmarks):
        if fr:
            a = np.array(fr, float)
            out[i] = np.c_[a[:, 0] * w, a[:, 1] * h, a[:, 2]]
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("videos", nargs="+", type=Path)
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    ap.add_argument("--out", type=Path, default=Path("e2e-python"))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    results = []
    for v in a.videos:
        frames, fps, stamps = decode(v)
        h, w = frames[0].shape[:2]
        lms = pose(frames, fps, a.model)
        probs, phases = swingnet(v)
        layers = dict(name=v.stem, width=w, height=h, nominalFPS=fps, timestamps=[r4(t) for t in stamps],
                      personCounts=[1 if f else 0 for f in lms], landmarks=lms, probabilities=probs, phases=phases)
        (a.out / f"{v.stem}.layers.json").write_text(json.dumps(layers), encoding="utf-8")
        if phases is None:
            r = {"verdict": "无法判断", "reason": "没有识别出挥杆阶段"}
        else:
            r = analyze(pixels(lms, w, h), *phases)
        r = {k: val for k, val in r.items() if k not in ("hands", "ref_line")}
        r.update(name=v.stem, phases=phases)
        results.append(r)
        print(f"{v.stem}: {w}x{h} {fps:.2f}fps {len(frames)} frames, phases {phases}, {r['verdict']} {r.get('reason', '')}",
              flush=True)
    (a.out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1, default=float),
                                        encoding="utf-8")


if __name__ == "__main__":
    main()
