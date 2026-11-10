"""Pick ~300 skeleton-benchmark frames (mostly downswing), balanced over views, one swing per video,
and save them as PNG (local only). View from address landmarks: shoulder spread / torso length."""
import json, os, random, zlib
from pathlib import Path
import cv2, numpy as np

B = Path(r"C:\Users\k8881\coachme-bench")
OUT = Path(os.environ.get("CM_POSE_OUT", B / "pose_bench")); (OUT / "frames").mkdir(parents=True, exist_ok=True)
random.seed(7)
rows = []
for src in [B / f"hd_part{i}/results.json" for i in range(4)] + [B / f"hd_swings/seg_p{i}/results.json" for i in range(4)] + ([Path(os.environ["CM_SEG"]) / "results.json"] if os.environ.get("CM_SEG") else []):
    if src.exists():
        rows += [dict(r, src=src.parent.name) for r in json.load(open(src, encoding="utf-8"))]
by_video = {}
for r in rows:
    by_video.setdefault(r["video"], []).append(r)
pool = {"dtl": [], "face_on": [], "angle": []}
for v, rs in by_video.items():
    r = random.choice(rs)
    ad, top, imp = r["phases"]
    if not (ad < top < imp): continue
    lm = np.load(r["lm"])
    a = np.nanmedian(lm[ad:ad + 5], axis=0)
    torso = np.linalg.norm((a[11, :2] + a[12, :2]) / 2 - (a[23, :2] + a[24, :2]) / 2)
    if not np.isfinite(torso) or torso < float(os.environ.get("CM_MIN_TORSO", 40)): continue  # golfer too small to label precisely
    spread = abs(a[11, 0] - a[12, 0]) / torso
    view = "face_on" if spread > 0.55 else "dtl" if spread < 0.3 else "angle"
    pool[view].append((r, torso, spread))
print({k: len(v) for k, v in pool.items()})
want = {"dtl": 100, "face_on": 100, "angle": 100}
man = []
for view, items in pool.items():
    random.shuffle(items)
    n_sw = max(1, -(-want[view] // 3))  # up to 3 frames per swing
    per = max(1, -(-want[view] // max(1, min(len(items), n_sw))))
    for r, torso, spread in items:
        if sum(m["view"] == view for m in man) >= want[view]: break
        ad, top, imp = r["phases"]
        fracs = [0.35, 0.7, 0.95][:per] if per <= 3 else list(np.linspace(0.2, 1.0, per))
        idx = sorted({int(round(top + f * (imp - top))) for f in fracs})
        cap = cv2.VideoCapture(r["video"]); cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
        for k in idx:
            cap.set(cv2.CAP_PROP_POS_FRAMES, k); ok, im = cap.read()
            if not ok: continue
            fid = f"{Path(r['video']).stem}_{k}"
            cv2.imwrite(str(OUT / "frames" / f"{fid}.png"), im)
            man.append({"id": fid, "video": r["video"], "frame": k, "phase_frac": round((k - top) / max(1, imp - top), 2),
                        "view": view, "torso_px": round(float(torso), 1), "spread": round(float(spread), 2),
                        "lm": r["lm"], "src": r["src"], "size": list(im.shape[:2])})
        cap.release()
(OUT / "manifest.json").write_text(json.dumps(man, indent=1), encoding="utf-8")
print(len(man), {v: sum(m["view"] == v for m in man) for v in want})
