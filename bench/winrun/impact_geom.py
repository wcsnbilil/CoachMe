"""Clip C impact-zone geometry: clubhead / ball blob centroids per frame, then ground-plane angles
relative to the camera axis (assumes DTL camera pointed down the target line, level roll).
Ground plane from horizon row + focal length. Local only."""
import json, sys
import cv2, numpy as np
from pathlib import Path

B = Path(r"C:\Users\49907\coachme-bench\niko_clips")
cap = cv2.VideoCapture(str(B / "niko_C_slomo120_portrait.mov")); cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
F = {}
n = 0
while True:
    ok, im = cap.read()
    if not ok: break
    if n in (342, 345, 350) or 430 <= n <= 446: F[n] = im
    n += 1
H, W = F[440].shape[:2]
# rough guesses (from contact sheet), refined by blob search in a window
HEAD = {436: (599, 1333), 437: (690, 1399), 438: (741, 1417), 439: (757, 1399), 440: (741, 1346),
        441: (714, 1299), 442: (679, 1250), 443: (643, 1194), 444: (610, 1133), 445: (563, 1077)}
BALL = {430: (730, 1325), 440: (733, 1321), 441: (701, 1237), 442: (667, 1150), 443: (639, 1077)}


def blob(im, c, r, dark):
    x, y = c
    x0, y0 = max(0, x - r), max(0, y - r)
    roi = cv2.cvtColor(im[y0:y + r, x0:x + r], cv2.COLOR_BGR2HSV)
    m = (roi[..., 2] < 70) if dark else ((roi[..., 2] > 200) & (roi[..., 1] < 60))
    m = m.astype(np.uint8)
    k, lab, st, cen = cv2.connectedComponentsWithStats(m)
    if k < 2: return None
    # nearest decent blob to the guess
    best = None
    for i in range(1, k):
        a = st[i, 4]
        if a < (60 if dark else 15): continue
        d = np.hypot(cen[i, 0] + x0 - x, cen[i, 1] + y0 - y)
        s = d - 0.02 * a
        if best is None or s < best[0]: best = (s, cen[i, 0] + x0, cen[i, 1] + y0, a)
    return None if best is None else (round(best[1], 1), round(best[2], 1), int(best[3]))


heads = {f: blob(F[f], c, 45, True) for f, c in HEAD.items()}
balls = {f: blob(F[f], c, 30, False) for f, c in BALL.items()}
print("heads", heads); print("balls", balls)

# horizon: fairway/tree boundary row = where green-ness drops, mid columns
g = F[342].astype(int)
greenness = (g[..., 1] - (g[..., 0] + g[..., 2]) / 2)[:, 300:800].mean(1)
print("greenness rows 600-800 step 10:", [round(float(greenness[r]), 1) for r in range(600, 800, 10)])


def ground(u, v, f, yh):
    # camera pitched down so that the horizon is at row yh; returns ground (lateral X right, forward Z) up to scale (h=1)
    cx, cy = W / 2, H / 2
    phi = np.arctan2(cy - yh, f)  # down-pitch
    d = np.array([(u - cx) / f, (v - cy) / f, 1.0])  # x right, y down, z fwd (camera)
    c, s = np.cos(phi), np.sin(phi)
    # world: X right, Y down, Z forward(horizontal). camera rotated down by phi about X.
    dw = np.array([d[0], c * d[1] + s * d[2], -s * d[1] + c * d[2]])
    t = 1.0 / dw[1]
    return np.array([dw[0] * t, dw[2] * t])


def ang(p, q, f, yh):
    a, b = ground(*p, f, yh), ground(*q, f, yh)
    v = b - a
    return float(np.degrees(np.arctan2(v[0], v[1])))  # + = right of camera axis (away from golfer for this RH DTL)


out = {"heads": heads, "balls": balls}
yhs = [int(a) for a in sys.argv[1].split(",")]
for f in (1150, 1390, 1650):
    for yh in yhs:
        r = {}
        hp = lambda k: heads[k][:2]
        r["path_438_440"] = ang(hp(438), hp(440), f, yh)
        r["path_439_441"] = ang(hp(439), hp(441), f, yh)
        r["path_437_441"] = ang(hp(437), hp(441), f, yh)
        r["path_436_440"] = ang(hp(436), hp(440), f, yh)
        r["toe_line"] = ang((322.2, 1437.7), (298.4, 1366.1), f, yh)  # near (trail) toe -> far (lead) toe
        r["heel_line"] = ang((211.0, 1438.8), (216.4, 1374.0), f, yh)
        r["ball_440_443"] = ang(balls[440][:2], balls[443][:2], f, yh)  # NB ball is airborne: biased, see notes
        print("f", f, "yh", yh, {k: round(v, 1) for k, v in r.items()})
        out[f"f{f}_yh{yh}"] = r
(B / "impact_geom.json").write_text(json.dumps(out, default=float, indent=1))
