"""Niko clip C impact zone: dump SAM clubhead track + a contact sheet of frames around impact (local only)."""
import json, sys
import cv2, numpy as np
from pathlib import Path

B = Path(r"C:\Users\49907\coachme-bench\niko_clips")
z = np.load(B / "club2/niko_C_slomo120_portrait.npz")
start = int(z["start"]); heads = z["heads"]; hands = z["hands"]
print("start", start, "side", z["side"], "torso", z["torso"], "feet", z["feet"])
for i, (h, hd) in enumerate(zip(heads, hands)):
    f = start + i
    if 405 <= f <= 445:
        print(f, np.round(h, 1), np.round(hd, 1))
lo, hi = int(sys.argv[1]), int(sys.argv[2])
cap = cv2.VideoCapture(str(B / "niko_C_slomo120_portrait.mov"))
cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
frames = {}
n = 0
while True:
    ok, im = cap.read()
    if not ok:
        break
    if lo <= n <= hi:
        frames[n] = im
    n += 1
print("frames", n, "shape", next(iter(frames.values())).shape)
x0, y0, x1, y1 = [int(v) for v in sys.argv[3].split(",")]
tiles = []
for f in range(lo, hi + 1):
    t = frames[f][y0:y1, x0:x1].copy()
    t = cv2.resize(t, None, fx=float(sys.argv[4]), fy=float(sys.argv[4]))
    # pixel grid every 50 px of source
    for gx in range((x0 // 50 + 1) * 50, x1, 50):
        X = int((gx - x0) * float(sys.argv[4])); cv2.line(t, (X, 0), (X, t.shape[0]), (0, 255, 255) if gx % 100 == 0 else (0, 120, 120), 1)
        if gx % 100 == 0: cv2.putText(t, str(gx), (X + 2, 12), 0, 0.35, (0, 255, 255), 1)
    for gy in range((y0 // 50 + 1) * 50, y1, 50):
        Y = int((gy - y0) * float(sys.argv[4])); cv2.line(t, (0, Y), (t.shape[1], Y), (0, 255, 255) if gy % 100 == 0 else (0, 120, 120), 1)
        if gy % 100 == 0: cv2.putText(t, str(gy), (2, Y - 2), 0, 0.35, (0, 255, 255), 1)
    cv2.putText(t, str(f), (5, t.shape[0] - 8), 0, 0.7, (0, 0, 255), 2)
    tiles.append(t)
cols = int(sys.argv[5])
while len(tiles) % cols:
    tiles.append(np.zeros_like(tiles[0]))
rows = [np.hstack(tiles[i:i + cols]) for i in range(0, len(tiles), cols)]
cv2.imwrite(str(B / f"impact_sheet_{lo}_{hi}.jpg"), np.vstack(rows), [cv2.IMWRITE_JPEG_QUALITY, 85])
