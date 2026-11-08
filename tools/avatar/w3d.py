"""MediaPipe world (3D) landmarks for the 3D-skeleton feasibility check.
usage: python w3d.py <out dir> golfdb <golfdb data dir> <view: down-the-line|face-on> <start> <count>
       python w3d.py <out dir> hd <hd_part dir> [...]   (only swings path_fault judged)
Saves <out>/<name>.npy = (frames, 33, 4) world x,y,z (m, hip-centred) + visibility, and <name>.json meta."""
import json, sys
from pathlib import Path
import cv2, numpy as np
import mediapipe as mp
from mediapipe.tasks import python as mpp
from mediapipe.tasks.python import vision
MODEL = Path(__file__).resolve().parents[2] / "CoachMe" / "Resources" / "pose_landmarker_heavy.task"
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
jobs = []
if sys.argv[2] == "golfdb":
    import pandas as pd
    d = Path(sys.argv[3]); df = pd.read_pickle(d / "golfDB.pkl"); df = df[df["view"] == sys.argv[4]]
    df = df.iloc[int(sys.argv[5]):int(sys.argv[5]) + int(sys.argv[6])]
    for row in df.itertuples():
        ev = np.asarray(row.events) - row.events[0]
        jobs.append((f"gdb_{row.id}", d / "videos_160" / f"{row.id}.mp4", 0, None, (int(ev[1]), int(ev[4]), int(ev[6])),
                     {"view": row.view, "player": row.player, "slow": int(row.slow), "youtube_id": row.youtube_id}))
else:
    for rep in sys.argv[3:]:
        for r in json.loads((Path(rep) / "results.json").read_text(encoding="utf-8")):
            if r.get("verdict") in (None, "无法判断") or not r.get("phases"): continue
            a, t, i = r["phases"]; lo = max(0, a - 10)
            jobs.append((f"hd_{r['name']}", Path(r["video"]), lo, i + 5, (a - lo, t - lo, i - lo), {"view": "down-the-line", "src": "hd"}))
for name, path, lo, hi, ph, meta in jobs:
    if (out / f"{name}.img.npy").exists() or not path.exists(): continue
    cap = cv2.VideoCapture(str(path)); fps = cap.get(cv2.CAP_PROP_FPS) or 30
    cap.set(cv2.CAP_PROP_POS_FRAMES, lo); frames = []
    while hi is None or lo + len(frames) <= hi:
        ok, img = cap.read()
        if not ok: break
        h, w = img.shape[:2]
        if h > 720: img = cv2.resize(img, (int(w * 720 / h), 720))
        frames.append(img)
    cap.release()
    opts = vision.PoseLandmarkerOptions(base_options=mpp.BaseOptions(model_asset_path=str(MODEL)), running_mode=vision.RunningMode.VIDEO, num_poses=1)
    W = np.full((len(frames), 33, 4), np.nan); I = np.full((len(frames), 33, 3), np.nan)
    with vision.PoseLandmarker.create_from_options(opts) as lm:
        for k, img in enumerate(frames):
            res = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB, data=cv2.cvtColor(img, cv2.COLOR_BGR2RGB)), int(k * 1000 / fps))
            if res.pose_world_landmarks:
                W[k] = [(p.x, p.y, p.z, res.pose_landmarks[0][j].visibility) for j, p in enumerate(res.pose_world_landmarks[0])]
                I[k] = [(p.x * img.shape[1], p.y * img.shape[0], p.z * img.shape[1]) for p in res.pose_landmarks[0]]
    np.save(out / f"{name}.npy", W); np.save(out / f"{name}.img.npy", I)
    (out / f"{name}.json").write_text(json.dumps({**meta, "phases": ph, "fps": fps}, ensure_ascii=False), encoding="utf-8")
    print(name, len(frames), flush=True)
