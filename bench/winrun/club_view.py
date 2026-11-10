"""Per-frame downswing view of a club_track npz: plane lines + tracked shaft. usage: club_view.py report_dir club_dir out.jpg [step]"""
import sys, json
from pathlib import Path
import cv2, numpy as np
sys.path.insert(0, r"C:\Users\49907\coachme-bench\coachme\tools\club")
import club_track as ct
rep, cd, out = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
step = int(sys.argv[4]) if len(sys.argv) > 4 else 1
r = json.loads((rep / "results.json").read_text(encoding="utf-8"))[0]
z = np.load(cd / f"{r['name']}.npz")
res = json.loads((cd / f"{r['name']}.json").read_text(encoding="utf-8"))
ad, top, imp = r["phases"]
frames, _ = ct.read_range(Path(r["video"]), ad, imp + 3)
lm = np.load(rep / "landmarks" / f"{r['name']}.npy").astype(float)
lm[~(lm[:, :, 2] >= 0.5), :2] = np.nan
heads, hands = z["heads"], z["hands"]
head0, hands0 = heads[0], hands[0]
shm = ct.mid(lm, ad, ct.LS, ct.RS)
tiles = []
for i in list(range(top - ad - 2 * step, imp - ad + 1, step)):
    if i < 0 or i >= len(frames):
        continue
    im = frames[i].copy()
    q0 = (hands0 + (hands0 - head0) * 2.5).astype(int)
    cv2.line(im, tuple(head0.astype(int)), tuple(q0), (0, 255, 0), 3)
    q1 = (head0 + (shm - head0) * 2.5).astype(int)
    cv2.line(im, tuple(head0.astype(int)), tuple(q1), (255, 160, 0), 3)
    if np.isfinite(heads[i]).all() and np.isfinite(hands[i]).all():
        cv2.line(im, tuple(hands[i].astype(int)), tuple(heads[i].astype(int)), (0, 255, 255), 5)
        cv2.circle(im, tuple(heads[i].astype(int)), 14, (0, 0, 255), 4)
    pl = res["plane_series"][i] if i < len(res["plane_series"]) else None
    cv2.putText(im, f"f{ad + i} plane={pl}", (20, 60), 0, 2, (255, 255, 255), 5)
    tiles.append(cv2.resize(im, (270, 480)))
while len(tiles) % 6:
    tiles.append(np.zeros_like(tiles[0]))
cv2.imwrite(out, np.vstack([np.hstack(tiles[k:k + 6]) for k in range(0, len(tiles), 6)]), [cv2.IMWRITE_JPEG_QUALITY, 85])
print({k: v for k, v in res.items() if k != "plane_series"})
