"""Synthetic test for the stick detector + ground geometry: paint an alignment stick on clip C's address frame
at known headings and check the recovered heading. (Real-stick validation waits for Niko's new clip.)"""
import sys
sys.path.insert(0, r"C:\Users\49907\coachme-bench\winrun")
import cv2, numpy as np
import target_line as T

V = r"C:\Users\49907\coachme-bench\niko_clips\niko_C_slomo120_portrait.mov"
LM = r"C:\Users\49907\coachme-bench\niko_clips\run_path_manual\landmarks\niko_C_slomo120_portrait.npy"
fr, fps, n = T.read_frames(V, {342, 460})
im0 = fr[342]; H, W = im0.shape[:2]
lm = np.median(np.load(LM)[342:347], axis=0)
torso = float(np.linalg.norm((lm[11, :2] + lm[12, :2]) / 2 - (lm[23, :2] + lm[24, :2]) / 2))
yh = T.horizon_row(im0); f = 0.72 * max(W, H); cam = T.Cam(W, H, f, yh)


def to_img(X, Z):
    c, s = np.cos(cam.phi), np.sin(cam.phi)
    dw = np.array([X, 1.0, Z])  # world: X right, Y down (ground 1 below camera), Z forward
    d = np.array([dw[0], c * dw[1] - s * dw[2], s * dw[1] + c * dw[2]])
    return (W / 2 + f * d[0] / d[2], H / 2 + f * d[1] / d[2])


ball = np.array([729.2, 1319.9])
toes = (lm[31, :2] + lm[32, :2]) / 2
start = cam.plane(*(0.5 * ball + 0.5 * toes + np.array([0, 40])))  # between feet and ball line, a bit nearer the camera
errs = []
for deg in (-15, -8, -3, 0, 4, 10):
    im = im0.copy()
    th = np.radians(deg); L = 2.2  # ground units (camera height = 1) ~ 3 m
    p = to_img(*start); q = to_img(start[0] + L * np.sin(th), start[1] + L * np.cos(th))
    COL = {"orange": (40, 120, 255), "white": (245, 245, 245), "yellow": (40, 230, 240), "red": (40, 40, 210)}[sys.argv[1] if len(sys.argv) > 1 else "orange"]
    WD = int(sys.argv[2]) if len(sys.argv) > 2 else 7
    for col, wd in ((COL, WD),):
        cv2.line(im, tuple(map(int, p)), tuple(map(int, q)), col, wd, cv2.LINE_AA)
    T.DBG.clear()
    stick, cands = T.find_stick(im, yh, lm, ball, torso)
    if deg == 0:
        print(" painted seg", list(map(int, p)), list(map(int, q)))
        for r, a_, b_ in T.DBG:
            # segments roughly on the painted line
            dd = q[0] - p[0], q[1] - p[1]; Ln = np.hypot(*dd)
            dist = max(abs(dd[0] * (pt[1] - p[1]) - dd[1] * (pt[0] - p[0])) / Ln for pt in (a_, b_))
            if dist < 15: print("  ", r, list(map(int, a_)), list(map(int, b_)))
    got = None if stick is None else cam.heading(stick[1], stick[2])
    errs.append(None if got is None else got - deg)
    print(f"painted {deg:+.0f}  found {None if got is None else round(got, 1)}  segment {None if stick is None else [list(map(int, stick[1])), list(map(int, stick[2]))]}")
    if deg == 4: cv2.imwrite(r"C:\Users\49907\coachme-bench\niko_clips\target\synthetic_stick.jpg", cv2.resize(im[900:], None, fx=0.5, fy=0.5))
print("errors", errs)
