"""Python side of the whole chain, keeping every layer for tools/e2e/layers.py.

  python tools/e2e/python_layers.py e2e-videos/*.mp4 --out e2e-python

For each video: OpenCV decode (size, fps, timestamps) -> MediaPipe heavy (VIDEO mode, one pose,
timestamps i*1000/fps, exactly as run_path.py) -> SwingNet (NumPy port, 64-frame chunks) ->
path_fault.analyze. Like the App, a clip over 8 s is first cut down to its last swing (select_swing), and a SwingNet pass that finds nothing is rerun on a crop around the
person (tools/benchmark/person_crop.py). Writes <out>/<name>.layers.json (same keys as the App's) and <out>/results.json
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
sys.path.insert(0, str(ROOT / "tools" / "split"))
from path_fault import analyze  # noqa: E402
import swing_split  # noqa: E402

# Same numbers as BetaAnalysisRunner: clips longer than this are split first, on a ~15 fps sample.
SPLIT_MIN_SECONDS = 8.0
SCOUT_FPS = 15.0


def select_swing(px: np.ndarray, stamps: list[float]):
    """The App's first pass (BetaAnalysisRunner.selectSwing): sample ~15 fps, find the swings, take the
    last one's padded window. -> (first frame, end frame, swings found, chosen) on the full-rate
    frames, or None = analyse whole. The App runs MediaPipe again on the sampled small frames; here
    the full-rate landmarks are sampled, which is the same motion."""
    if not stamps or stamps[-1] <= SPLIT_MIN_SECONDS:
        return None
    keep, last = [], -np.inf
    for i, t in enumerate(stamps):
        if t - last >= 1 / SCOUT_FPS - 0.004:
            keep.append(i)
            last = t
    if len(keep) < 10:
        return None
    t = np.array(stamps)[keep]
    steps = np.diff(t)
    steps = steps[steps > 0]
    fps = 1 / float(np.median(steps)) if len(steps) else 30.0
    swings = swing_split.find_swings(px[keep], fps)
    wins = swing_split.windows(swings, len(keep), fps, single=True)
    if not wins:
        return None, len(swings)
    a, b = wins[-1]
    start, end = t[a], min(stamps[-1], t[min(b, len(keep)) - 1] + 1 / fps)
    inside = [i for i, x in enumerate(stamps) if start - 1e-6 <= x <= end + 1e-6]
    return (inside[0], inside[-1] + 1, len(wins), len(wins)), len(swings)


def r4(v: float) -> float:
    return round(float(v), 4)


def decode(path: Path):
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)  # iPhone portrait clips carry rotation metadata; OpenCV ignores it by default
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
            out.append([[r4(p.x), r4(p.y), r4(p.visibility), r4(p.presence)] for p in res.pose_landmarks[0]]
                       if res.pose_landmarks else [])
    return out


def swingnet(path: Path, landmarks, lo: int = 0, hi: int | None = None):
    """Main pass on the whole frame; when it finds no phases, the App's person-crop rerun.
    lo:hi = the frames of the chosen swing (phases are relative to lo)."""
    from golfdb_eval import load_model, probabilities, read_frames
    from person_crop import estimate, phases_from_probs, read_frames_cropped
    model = load_model("numpy")
    probs = probabilities(model, read_frames(path)[lo:hi])
    phases, crop = phases_from_probs(probs), None
    if phases is None:
        crop = estimate(landmarks[lo:hi])
        if crop is not None:
            phases = phases_from_probs(probabilities(model, read_frames_cropped(path, crop)[lo:hi]))
    return [[r4(v) for v in row] for row in probs], phases, crop


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
        px = pixels(lms, w, h)
        sel = select_swing(px, stamps)
        found = None
        if sel is not None:
            sel, found = sel
        lo, hi = (sel[0], sel[1]) if sel else (0, len(frames))
        probs, phases, crop = swingnet(v, lms, lo, hi)
        layers = dict(name=v.stem, width=w, height=h, nominalFPS=fps, timestamps=[r4(t) for t in stamps[lo:hi]],
                      personCounts=[1 if f else 0 for f in lms[lo:hi]], landmarks=lms[lo:hi], probabilities=probs,
                      phases=phases, personCrop=crop)
        (a.out / f"{v.stem}.layers.json").write_text(json.dumps(layers), encoding="utf-8")
        if phases is None:
            r = {"verdict": "无法判断", "reason": "没有识别出挥杆阶段"}
        else:
            r = analyze(px[lo:hi], *phases)
        r = {k: val for k, val in r.items() if k not in ("hands", "ref_line")}
        r.update(name=v.stem, phases=phases, phaseOffset=lo, swingsFound=found,
                 swingChosen=sel[3] if sel else None,
                 windowSeconds=[r4(stamps[lo]), r4(stamps[hi - 1])] if sel else None)
        results.append(r)
        print(f"{v.stem}: {w}x{h} {fps:.2f}fps {len(frames)} frames, swings {found}, window {lo}:{hi}, phases {phases}"
              f"{' (person crop)' if crop else ''}, {r['verdict']} {r.get('reason', '')}",
              flush=True)
    (a.out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1, default=float),
                                        encoding="utf-8")


if __name__ == "__main__":
    main()
