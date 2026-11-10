import sys
sys.path.insert(0, r"C:\Users\49907\coachme-bench\winrun")
import cv2, numpy as np
import target_line as T
fr, fps, n = T.read_frames(r"C:\Users\49907\coachme-bench\niko_clips\niko_C_slomo120_portrait.mov", {342})
im = fr[342].copy()
cv2.line(im, (519, 1401), (529, 1088), (40, 120, 255), 7, cv2.LINE_AA)
lab = cv2.cvtColor(cv2.GaussianBlur(im, (3, 3), 0), cv2.COLOR_BGR2LAB).astype(np.float32)
e = np.zeros(im.shape[:2], np.uint8)
for ch in range(3):
    e |= cv2.Canny(lab[..., ch].astype(np.uint8), 30, 90)
print("edge px in strip", e[1100:1390, 505:545].sum() / 255, "of rows", 290)
segs = cv2.HoughLinesP(e, 1, np.pi / 360, 60, minLineLength=130, maxLineGap=12)
print("n segs", 0 if segs is None else len(segs))
for s in segs.reshape(-1, 4):
    if 490 < s[0] < 560 and 490 < s[2] < 560: print(s)
print("lab at line", lab[1250, 524], "grass", lab[1250, 560])
