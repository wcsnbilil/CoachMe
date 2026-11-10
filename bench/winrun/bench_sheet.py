"""Labelling sheet for one benchmark frame: crop around the golfer (box from landmark extent only; no keypoints drawn),
upscaled so the torso is ~300 px, with a source-pixel grid every 10 px (labels every 50). Usage: bench_sheet.py ID [part]
part: 'up' (head..hips), 'low' (hips..feet), 'all'."""
import json, sys
from pathlib import Path
import cv2, numpy as np

B = Path(r"C:\Users\49907\coachme-bench"); OUT = B / "pose_bench"
man = {m["id"]: m for m in json.load(open(OUT / "manifest.json", encoding="utf-8"))}
m = man[sys.argv[1]]; part = sys.argv[2] if len(sys.argv) > 2 else "all"
im = cv2.imread(str(OUT / "frames" / f"{m['id']}.png")); H, W = im.shape[:2]
lm = np.load(m["lm"])[m["frame"]]
ok = np.isfinite(lm[:, 0])
x0, y0, x1, y1 = lm[ok, 0].min(), lm[ok, 1].min(), lm[ok, 0].max(), lm[ok, 1].max()
t = m["torso_px"]; pad = 0.6 * t
x0, x1 = max(0, x0 - pad), min(W, x1 + pad); y0, y1 = max(0, y0 - pad), min(H, y1 + 0.3 * t)
if part == "up": y1 = min(H, y0 + (y1 - y0) * 0.62)
if part == "low": y0 = y0 + (y1 - y0) * 0.45
x0, y0, x1, y1 = map(int, (x0, y0, x1, y1))
s = float(sys.argv[3]) if len(sys.argv) > 3 else max(1.0, 300 / t)
c = cv2.resize(im[y0:y1, x0:x1], None, fx=s, fy=s, interpolation=cv2.INTER_CUBIC)
for gx in range((x0 // 10 + 1) * 10, x1, 10):
    X = int((gx - x0) * s); major = gx % 50 == 0
    cv2.line(c, (X, 0), (X, c.shape[0]), (0, 255, 255) if major else (0, 140, 140), 1)
    if major: cv2.putText(c, str(gx), (X + 2, 12), 0, 0.4, (0, 255, 255), 1); cv2.putText(c, str(gx), (X + 2, c.shape[0] - 4), 0, 0.4, (0, 255, 255), 1)
for gy in range((y0 // 10 + 1) * 10, y1, 10):
    Y = int((gy - y0) * s); major = gy % 50 == 0
    cv2.line(c, (0, Y), (c.shape[1], Y), (0, 255, 255) if major else (0, 140, 140), 1)
    if major: cv2.putText(c, str(gy), (2, Y - 2), 0, 0.4, (0, 255, 255), 1); cv2.putText(c, str(gy), (c.shape[1] - 34, Y - 2), 0, 0.4, (0, 255, 255), 1)
cv2.imwrite(str(OUT / "sheet.jpg"), c, [cv2.IMWRITE_JPEG_QUALITY, 90])
print(m["id"], m["view"], "torso", t, "crop", [x0, y0, x1, y1], "scale", round(s, 2), "out", c.shape[:2])
