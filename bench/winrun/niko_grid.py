"""Frames with a pixel grid for hand-marking the shaft. usage: niko_grid.py video out.jpg x0 y0 x1 y1 f1 f2 ..."""
import sys
import cv2, numpy as np
v, out = sys.argv[1], sys.argv[2]
x0, y0, x1, y1 = map(int, sys.argv[3:7])
want = list(map(int, sys.argv[7:]))
c = cv2.VideoCapture(v); c.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
F = {}; i = 0
while True:
    ok, im = c.read()
    if not ok: break
    if i in want: F[i] = im
    i += 1
tiles = []
for f in want:
    im = F[f][y0:y1, x0:x1].copy()
    for gx in range((x0 // 50 + 1) * 50, x1, 50):
        cv2.line(im, (gx - x0, 0), (gx - x0, y1 - y0), (0, 255, 255) if gx % 100 == 0 else (0, 140, 140), 1)
        if gx % 100 == 0: cv2.putText(im, str(gx), (gx - x0 + 2, 14), 0, 0.45, (0, 255, 255), 1)
    for gy in range((y0 // 50 + 1) * 50, y1, 50):
        cv2.line(im, (0, gy - y0), (x1 - x0, gy - y0), (0, 255, 255) if gy % 100 == 0 else (0, 140, 140), 1)
        if gy % 100 == 0: cv2.putText(im, str(gy), (2, gy - y0 - 2), 0, 0.45, (0, 255, 255), 1)
    cv2.putText(im, f"f{f}", (x1 - x0 - 70, 30), 0, 0.9, (0, 0, 255), 2)
    tiles.append(im)
cols = 3
while len(tiles) % cols: tiles.append(np.zeros_like(tiles[0]))
cv2.imwrite(out, np.vstack([np.hstack(tiles[k:k + cols]) for k in range(0, len(tiles), cols)]), [cv2.IMWRITE_JPEG_QUALITY, 90])
