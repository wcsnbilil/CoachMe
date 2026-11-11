"""Python port of the App's SwingNet fallback (CoachMeCore PersonCrop + SavedSwingPhaseAnalysis).

When SwingNet finds no consistent phases on the whole frame (a small person in a landscape clip),
the App crops a stable box around the golfer from the pose landmarks and runs SwingNet again on
that crop. Keep in step with PersonCrop.swift and SwingNetPhaseDetector.normalizedInput(crop:).
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

JOINTS = [0, 11, 12, 23, 24, 25, 26, 27, 28]  # nose, shoulders, hips, knees, ankles


def estimate(landmarks) -> tuple[float, float, float, float] | None:
    """landmarks: per frame a list of 33 [x, y, visibility, presence] normalised, or [] when no pose.
    Returns (x, y, width, height) normalised, or None like PersonCrop.estimate."""
    boxes = []
    for fr in landmarks:
        if len(fr) != 33:
            continue
        pts = []
        for j in JOINTS:
            p = fr[j]
            x, y = p[0], p[1]
            presence = p[3] if len(p) > 3 and p[3] is not None else 1.0
            if np.isfinite(x) and np.isfinite(y) and 0 <= x <= 1 and 0 <= y <= 1 and presence >= 0.5:
                pts.append((x, y))
        if len(pts) < 7:
            continue
        a = np.array(pts)
        boxes.append([a[:, 0].min(), a[:, 1].min(), a[:, 0].max(), a[:, 1].max()])
    if len(boxes) < 12:
        return None
    b = np.sort(np.array(boxes), axis=0)
    n = len(b)
    med = (b[(n - 1) // 2] + b[n // 2]) / 2
    h = med[3] - med[1]
    cx, cy = (med[0] + med[2]) / 2, (med[1] + med[3]) / 2
    if h <= 0.08:
        return None
    left, right = max(0.0, cx - h * 0.55), min(1.0, cx + h * 0.55)
    top, bottom = max(0.0, cy - h * 0.7), min(1.0, cy + h * 0.7)
    if right - left <= 0.05 or bottom - top <= 0.05:
        return None
    return float(left), float(top), float(right - left), float(bottom - top)


def read_frames_cropped(path: Path, crop) -> np.ndarray:
    """golfdb_eval.read_frames on the crop box (pixel box rounded down like the App)."""
    import cv2
    from golfdb_eval import MEAN, STD
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    out = []
    while True:
        ok, img = cap.read()
        if not ok:
            break
        H, W = img.shape[:2]
        cw, ch = max(1, int(W * crop[2])), max(1, int(H * crop[3]))
        ox, oy = int(W * crop[0]), int(H * crop[1])
        img = img[oy:oy + ch, ox:ox + cw]
        h, w = img.shape[:2]
        r = 160 / max(h, w)
        nh, nw = max(1, int(h * r)), max(1, int(w * r))
        img = cv2.resize(img, (nw, nh))
        top, left = (160 - nh) // 2, (160 - nw) // 2
        img = cv2.copyMakeBorder(img, top, 160 - nh - top, left, 160 - nw - left, cv2.BORDER_CONSTANT,
                                 value=[0.406 * 255, 0.456 * 255, 0.485 * 255])
        rgb = cv2.cvtColor(img, cv2.COLOR_BGR2RGB).astype(np.float32) / 255
        out.append((rgb.transpose(2, 0, 1) - MEAN) / STD)
    cap.release()
    return np.stack(out).astype(np.float32)


def phases_from_probs(probs):
    from app_selector import SwingNetEventSelector
    sel = SwingNetEventSelector()
    for t, row in enumerate(probs):
        sel.append(list(map(float, row)), float(t))
    marks = sel.keyframes()
    return None if not marks else [int(marks["address"][0]), int(marks["top"][0]), int(marks["impact"][0])]
