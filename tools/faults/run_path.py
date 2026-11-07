"""Run the 外下 / 内下 prototype and write a contact sheet to check by eye.

GolfDB (uses its labelled address/top/impact frames, down-the-line clips only):
  python tools/faults/run_path.py --golfdb ~/coachme-bench/golfdb/data --limit 60

Your own down-the-line video (phases from the app's SwingNet):
  python tools/faults/run_path.py --video my_swing.mov

Pose landmarks are cached in <out>/landmarks/, so a second run with new
thresholds (--calibration calibration.json) takes seconds, not an hour.

Needs: mediapipe, opencv-python-headless, numpy, pandas, coremltools, and
CoachMe/Resources/pose_landmarker_heavy.task (tools/download-model.sh).
Output: <out>/index.html with one image per swing (blue = backswing hands,
red = downswing hands, drawn on the top-of-backswing frame) and results.json.
"""

from __future__ import annotations

import argparse
import html
import json
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "tools" / "benchmark"))
from path_fault import DEFAULT_CALIBRATION, MAX_LINE_WIDTH, analyze  # noqa: E402


def read_video(path: Path):
    cap = cv2.VideoCapture(str(path))
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    frames = []
    while True:
        ok, img = cap.read()
        if not ok:
            break
        frames.append(img)
    cap.release()
    return frames, fps


def pose_landmarks(frames, fps, model: Path) -> np.ndarray:
    import mediapipe as mp
    from mediapipe.tasks import python as mpp
    from mediapipe.tasks.python import vision

    opts = vision.PoseLandmarkerOptions(base_options=mpp.BaseOptions(model_asset_path=str(model)),
                                        running_mode=vision.RunningMode.VIDEO, num_poses=1)
    out = np.full((len(frames), 33, 3), np.nan)
    with vision.PoseLandmarker.create_from_options(opts) as lm:
        for i, img in enumerate(frames):
            h, w = img.shape[:2]
            rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)
            res = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb), int(i * 1000 / fps))
            if res.pose_landmarks:
                out[i] = [(p.x * w, p.y * h, p.visibility) for p in res.pose_landmarks[0]]
    return out


def swingnet_phases(path: Path, backend: str) -> tuple[int, int, int] | None:
    from golfdb_eval import load_model, probabilities, read_frames
    from app_selector import SwingNetEventSelector
    probs = probabilities(load_model(backend), read_frames(path))
    sel = SwingNetEventSelector()
    for t, row in enumerate(probs):
        sel.append(list(map(float, row)), float(t))
    marks = sel.keyframes()
    if not marks:
        return None
    return int(marks["address"][0]), int(marks["top"][0]), int(marks["impact"][0])


def draw(frames, result, a, t, i, title) -> np.ndarray:
    img = frames[t].copy()
    scale = max(1, int(480 / max(img.shape[:2])))
    img = cv2.resize(img, None, fx=scale, fy=scale, interpolation=cv2.INTER_NEAREST)
    if "hands" in result:
        pts = np.array(result["hands"]) * scale
        for seg, color in ((pts[a:t + 1], (255, 120, 0)), (pts[t:i + 1], (0, 0, 255))):
            seg = seg[np.isfinite(seg).all(axis=1)].astype(int)
            if len(seg) > 1:
                cv2.polylines(img, [seg.reshape(-1, 1, 2)], False, color, 2)
    if "ref_line" in result:  # address line hands -> shoulders, extended past the top (green)
        (x0, y0), (x1, y1) = result["ref_line"]
        far = (x0 + (x1 - x0) * 2.5, y0 + (y1 - y0) * 2.5)
        cv2.line(img, (int(x0 * scale), int(y0 * scale)), (int(far[0] * scale), int(far[1] * scale)), (0, 200, 0), 1)
    return img


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--golfdb", type=Path)
    p.add_argument("--video", type=Path, action="append", default=[])
    p.add_argument("--limit", type=int, default=60)
    p.add_argument("--backend", choices=["numpy", "coreml"], default="numpy")
    p.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    p.add_argument("--out", type=Path, default=Path("path_fault_report"))
    p.add_argument("--phases", help="manual address,top,impact frame numbers for a single --video")
    p.add_argument("--calibration", type=Path, help="calibration.json from calibrate.py")
    p.add_argument("--max-line-width", type=float, default=MAX_LINE_WIDTH,
                   help="refuse clips whose shoulder/hip line at address is wider than this (torso lengths)")
    a = p.parse_args()
    if not a.model.exists():
        sys.exit(f"missing {a.model}; run tools/download-model.sh")
    a.out.mkdir(parents=True, exist_ok=True)
    cache = a.out / "landmarks"
    cache.mkdir(exist_ok=True)
    cal = json.loads(a.calibration.read_text()) if a.calibration else None

    jobs = []  # (name, video path, phases or None, extra fields for results.json)
    if a.golfdb:
        import pandas as pd
        df = pd.read_pickle(a.golfdb / "golfDB.pkl")
        df = df[df["view"] == "down-the-line"].head(a.limit)
        for row in df.itertuples():
            ev = np.asarray(row.events) - row.events[0]
            jobs.append((f"golfdb_{row.id}", a.golfdb / "videos_160" / f"{row.id}.mp4",
                         (int(ev[1]), int(ev[4]), int(ev[6])),  # address, top, impact
                         {"id": int(row.id), "player": row.player, "slow": int(row.slow),
                          "youtube_id": row.youtube_id, "club": row.club}))
    manual = tuple(int(x) for x in a.phases.split(",")) if a.phases else None
    for v in a.video:
        jobs.append((v.stem, v, manual, {}))

    results = []
    for n, (name, path, phases, extra) in enumerate(jobs, 1):
        if not path.exists():
            continue
        frames, fps = read_video(path)
        phases = phases or swingnet_phases(path, a.backend)
        if phases is None:
            r = {"verdict": "无法判断", "reason": "没有识别出挥杆阶段"}
        else:
            npy = cache / f"{name}.npy"
            if npy.exists():
                lms = np.load(npy)
            else:
                lms = pose_landmarks(frames, fps, a.model)
                np.save(npy, lms)
            r = analyze(lms, *phases, calibration=cal, max_line_width=a.max_line_width)
            cv2.imwrite(str(a.out / f"{name}.jpg"), draw(frames, r, *phases, name))
        r.update(name=name, phases=phases, **extra)
        results.append(r)
        print(f"{n}/{len(jobs)} {name}: {r['verdict']} {r.get('offset', '')} {r.get('reason', '')}", flush=True)

    (a.out / "results.json").write_text(json.dumps(
        [{k: v for k, v in r.items() if k != "hands"} for r in results], ensure_ascii=False, indent=1))
    cards = "".join(
        f"<figure><img src='{html.escape(r['name'])}.jpg'><figcaption><b>{html.escape(r['verdict'])}</b> "
        f"offset={r.get('offset', '—')}<br>{html.escape(r['name'])} {html.escape(str(r.get('player', '')))}{' 慢动作' if r.get('slow') else ''} {html.escape(r.get('reason', ''))}</figcaption></figure>"
        for r in sorted(results, key=lambda r: -(r.get("offset") or -9)))
    (a.out / "index.html").write_text(
        "<meta charset=utf-8><title>外下/内下 目测检查</title><style>body{font:14px sans-serif;margin:16px}"
        "figure{display:inline-block;margin:6px;width:240px;vertical-align:top}img{width:240px}</style>"
        "<h1>外下 / 内下 目测检查</h1><p>蓝线=上杆双手轨迹，红线=下杆双手轨迹，绿线=准备姿势时双手到肩膀的参考线，画在上杆顶点那一帧上。"
        "红线在绿线靠球一侧=外下；在身体一侧=内下（蓝线只作参考，上杆很内不算外下）。按 offset 从大到小排序。"
        f"阈值：{html.escape(json.dumps(cal or DEFAULT_CALIBRATION, ensure_ascii=False))}</p>" + cards)
    verdicts = {}
    for r in results:
        verdicts[r["verdict"]] = verdicts.get(r["verdict"], 0) + 1
    print(json.dumps(verdicts, ensure_ascii=False), f"\nopen {a.out / 'index.html'}")


if __name__ == "__main__":
    main()
