"""Benchmark CoachMe's swing-phase detection on GolfDB.

Scores two things per swing, with GolfDB's own tolerance
(max(round((impact - address) / 30), 1) frames):

  official : SwingNet's raw per-event argmax over the clip (as in GolfDB eval.py)
  app      : what CoachMe shows, via the Python port of SwingNetEventSelector,
             including the swings where the app returns no automatic marks

The shipped checkpoint (swingnet_1800) was trained on GolfDB splits 2-4, so
only split 1 is a fair test. Other splits are reported but flagged.

Data: GolfDB annotations (data/golfDB.pkl from github.com/wmcnally/golfdb) and
its preprocessed 160x160 clips (data/videos_160/<id>.mp4, see that repo's
README). Frames are fed in 64-frame chunks without padding, exactly like the app.

Examples:
  python tools/benchmark/golfdb_eval.py --golfdb ~/golfdb/data --backend coreml --split 1
  python tools/benchmark/golfdb_eval.py --video some_swing.mp4 --backend numpy
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_selector import APP_EVENTS, SwingNetEventSelector, softmax  # noqa: E402

EVENTS = ["address", "toeUp", "midBackswing", "top", "midDownswing", "impact", "midFollowThrough", "finish"]
APP_PHASE_OF_EVENT = {0: "address", 1: "takeaway", 2: "midBackswing", 3: "top",
                      4: "midDownswing", 5: "impact", 7: "finish"}
MEAN = np.array([0.485, 0.456, 0.406], np.float32)[:, None, None]
STD = np.array([0.229, 0.224, 0.225], np.float32)[:, None, None]


def read_frames(path: Path) -> np.ndarray:
    """RGB, aspect-fit to 160 with ImageNet mean-colour border, normalized: [N,3,160,160]."""
    import cv2
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)  # iPhone portrait clips carry rotation metadata; OpenCV ignores it by default
    out = []
    while True:
        ok, img = cap.read()
        if not ok:
            break
        h, w = img.shape[:2]
        if (h, w) != (160, 160):
            r = 160 / max(h, w)
            nh, nw = int(h * r), int(w * r)
            img = cv2.resize(img, (nw, nh))
            top, left = (160 - nh) // 2, (160 - nw) // 2
            img = cv2.copyMakeBorder(img, top, 160 - nh - top, left, 160 - nw - left, cv2.BORDER_CONSTANT,
                                     value=[0.406 * 255, 0.456 * 255, 0.485 * 255])
        rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255
        out.append((rgb.transpose(2, 0, 1) - MEAN) / STD)
    cap.release()
    if not out:
        raise RuntimeError(f"no frames decoded from {path}")
    return np.stack(out).astype(np.float32)


def probabilities(model, frames: np.ndarray) -> np.ndarray:
    feats = model.encode(frames)
    rows = []
    for s in range(0, len(feats), 64):  # app and GolfDB both use 64-frame chunks, no padding
        rows.extend(softmax(list(map(float, r))) for r in model.sequence(feats[s:s + 64]))
    return np.array(rows)


def tolerance(events: np.ndarray) -> int:
    return int(max(np.round((events[5] - events[0]) / 30), 1))


def score(probs: np.ndarray, events: np.ndarray) -> dict:
    tol = tolerance(events)
    official = np.argmax(probs[:, :8], axis=0)
    selector = SwingNetEventSelector()
    for t, row in enumerate(probs):
        selector.append(list(map(float, row)), float(t))
    marks = selector.keyframes()
    app = {}
    for e in APP_EVENTS:
        mark = marks.get(APP_PHASE_OF_EVENT[e])
        app[EVENTS[e]] = None if mark is None else int(mark[0])
    return {
        "tolerance": tol,
        "truth": [int(x) for x in events],
        "official": [int(x) for x in official],
        "official_correct": [bool(abs(int(p) - int(g)) <= tol) for p, g in zip(official, events)],
        "app": app,
        "app_empty": not marks,
        "app_correct": {k: (v is not None and abs(v - int(events[EVENTS.index(k)])) <= tol) for k, v in app.items()},
    }


def summarize(results: list[dict]) -> dict:
    if not results:
        return {}
    oc = np.array([r["official_correct"] for r in results], float)
    app_keys = [EVENTS[e] for e in APP_EVENTS]
    ac = np.array([[r["app_correct"][k] for k in app_keys] for r in results], float)
    return {
        "swings": len(results),
        "official_pce": round(oc.mean(), 4),
        "official_pce_without_address_finish": round(oc[:, 1:7].mean(), 4),
        "official_per_event": {EVENTS[i]: round(oc[:, i].mean(), 4) for i in range(8)},
        "app_pce": round(ac.mean(), 4),
        "app_per_phase": {APP_PHASE_OF_EVENT[e]: round(ac[:, i].mean(), 4) for i, e in enumerate(APP_EVENTS)},
        "app_no_marks_rate": round(np.mean([r["app_empty"] for r in results]), 4),
    }


def load_model(backend: str):
    if backend == "coreml":
        from swingnet_mil import CoreMLSwingNet
        return CoreMLSwingNet()
    from swingnet_mil import NumpySwingNet
    return NumpySwingNet()


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--golfdb", type=Path, help="GolfDB data dir containing golfDB.pkl and videos_160/")
    p.add_argument("--video", type=Path, help="score-free run on one video: print the app's marks")
    p.add_argument("--backend", choices=["numpy", "coreml"], default="numpy")
    p.add_argument("--split", type=int, default=1)
    p.add_argument("--limit", type=int, help="only the first N swings (quick check)")
    p.add_argument("--out", type=Path, default=Path("golfdb_results.json"))
    a = p.parse_args()
    model = load_model(a.backend)

    if a.video:
        probs = probabilities(model, read_frames(a.video))
        sel = SwingNetEventSelector()
        for t, row in enumerate(probs):
            sel.append(list(map(float, row)), float(t))
        print(json.dumps({"frames": len(probs),
                          "official_argmax": {EVENTS[i]: int(np.argmax(probs[:, i])) for i in range(8)},
                          "app_marks": {k: {"frame": int(v[0]), "score": round(v[1], 4)} for k, v in sel.keyframes().items()}},
                         ensure_ascii=False, indent=1))
        return

    import pandas as pd
    df = pd.read_pickle(a.golfdb / "golfDB.pkl")
    df = df[df["split"] == a.split]
    if a.limit:
        df = df.head(a.limit)
    if a.split != 1:
        print("WARNING: swingnet_1800 was trained on this split; numbers are optimistic.", file=sys.stderr)
    results, missing = [], 0
    started = time.time()
    for n, row in enumerate(df.itertuples(), 1):
        path = a.golfdb / "videos_160" / f"{row.id}.mp4"
        if not path.exists():
            missing += 1
            continue
        events = np.asarray(row.events)
        events = (events - events[0])[1:-1]  # clip-relative frames of the 8 labelled events
        r = score(probabilities(model, read_frames(path)), events)
        r.update(id=int(row.id), slow=int(row.slow), view=row.view, club=row.club)
        results.append(r)
        if n % 10 == 0:
            print(f"{n}/{len(df)}  {time.time() - started:.0f}s  app PCE so far {summarize(results)['app_pce']}",
                  file=sys.stderr)
    report = {"backend": a.backend, "split": a.split, "missing_videos": missing,
              "all": summarize(results),
              "real_time": summarize([r for r in results if r["slow"] == 0]),
              "slow_motion": summarize([r for r in results if r["slow"] == 1]),
              "by_view": {v: summarize([r for r in results if r["view"] == v])
                          for v in sorted({r["view"] for r in results})},
              "swings": results}
    a.out.write_text(json.dumps(report, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("backend", "split", "missing_videos", "all", "real_time", "slow_motion")},
                     ensure_ascii=False, indent=1))
    print(f"full per-swing results: {a.out}")


if __name__ == "__main__":
    main()
