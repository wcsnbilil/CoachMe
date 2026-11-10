import sys
sys.path.insert(0, r"C:\Users\49907\coachme-bench\winrun")
import cv2, numpy as np
from target_line import read_frames
fr, fps, n = read_frames(r"C:\Users\49907\coachme-bench\niko_clips\niko_C_slomo120_portrait.mov", {342, 462})
im, late = fr[342], fr[462]
hsv = cv2.cvtColor(im, cv2.COLOR_BGR2HSV); hl = cv2.cvtColor(late, cv2.COLOR_BGR2HSV)
wa = (hsv[..., 2] > 190) & (hsv[..., 1] < 70)
wl = cv2.dilate(((hl[..., 2] > 190) & (hl[..., 1] < 70)).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
m = cv2.morphologyEx((wa & ~wl).astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
k, _, st, cen = cv2.connectedComponentsWithStats(m)
for i in range(1, k):
    if st[i, 4] > 20: print(st[i], np.round(cen[i]))
print("ball patch HSV", hsv[1310:1330, 722:742].reshape(-1, 3).mean(0), "late", hl[1310:1330, 722:742].reshape(-1, 3).mean(0))
