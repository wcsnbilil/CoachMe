import sys, json
from pathlib import Path
import cv2, numpy as np
sys.path.insert(0, r"C:\Users\49907\coachme-bench\winrun")
import club_track2 as c2
ct = c2.ct
rep, out = Path(sys.argv[1]), Path(sys.argv[2])
r = json.loads((rep / "results.json").read_text(encoding="utf-8"))[0]
lm = np.load(rep / "landmarks" / f"{r['name']}.npy").astype(float)
lm[~(lm[:, :, 2] >= 0.5), :2] = np.nan
ad, top, imp = r["phases"]
frames, _ = ct.read_range(Path(r["video"]), ad, imp + 3)
hands0 = ct.hands_at(lm, ad)
torso = float(np.linalg.norm(ct.mid(lm, ad, ct.LS, ct.RS) - ct.mid(lm, ad, ct.LH, ct.RH)))
ank = lm[ad, [27, 28], :2]
print("hands", hands0, "torso", torso, "ankles", ank)
t = c2.thin_response(frames[0], torso)
print("thin p90", np.percentile(t, 90), "p99", np.percentile(t, 99))
found = c2.address_shaft(frames[0], hands0, torso, float(np.nanmean(ank[:, 1])), float(np.nanmean(ank[:, 0])))
orig = c2._orig_address(frames[0], hands0, torso, float(np.nanmean(ank[:, 1])), float(np.nanmean(ank[:, 0])))
print("cands", c2.CANDS[:8])
print("radial", None if found is None else found[0], "hough", None if orig is None else orig[0])
im = frames[0].copy()
cv2.circle(im, tuple(hands0.astype(int)), 10, (0, 0, 255), 3)
if found is not None:
    cv2.line(im, tuple(hands0.astype(int)), tuple(found[0].astype(int)), (0, 255, 0), 3)
if orig is not None:
    cv2.line(im, tuple(hands0.astype(int)), tuple(orig[0].astype(int)), (255, 0, 0), 2)
tv = np.clip(t * 3, 0, 255).astype(np.uint8)
cv2.imwrite(str(out / "dbg_address.jpg"), np.hstack([cv2.resize(im, (540, 960)), cv2.cvtColor(cv2.resize(tv, (540, 960)), cv2.COLOR_GRAY2BGR)]))
