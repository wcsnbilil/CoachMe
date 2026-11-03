"""Prototype: over-the-top (外下) / too-inside (内下) from a down-the-line video.

Python first, Swift later. Uses only 2D MediaPipe landmarks plus three phase
frames (address, top, impact).

Signal (down-the-line camera, image x runs from the golfer's body toward the
ball line): at the same hand height, compare where the hands are on the way
down with where they were on the way up.

    offset = (x_down - x_up) * side / torso_length

offset > 0: hands come down outside (toward the ball) of the backswing path,
            the classic over-the-top loop
offset < 0: hands come down inside / behind the backswing path (too inside)

This is a hand-path proxy. The club itself is not tracked, so it measures
the loop of the hands, not the clubhead path. Thresholds are provisional and
are meant to be checked by eye on the contact sheet this tool writes.
"""

from __future__ import annotations

import numpy as np

# MediaPipe pose indices
NOSE, L_SH, R_SH, L_HIP, R_HIP, L_WR, R_WR = 0, 11, 12, 23, 24, 15, 16

PROVISIONAL_OUTSIDE = 0.10  # offset above this -> 外下倾向 (to be calibrated by eye)
PROVISIONAL_INSIDE = -0.10  # offset below this -> 内下倾向


def _smooth(track: np.ndarray, k: int = 3) -> np.ndarray:
    """Moving average over frames, edge-padded; NaNs are interpolated first."""
    out = track.copy()
    for d in range(out.shape[1]):
        col = out[:, d]
        ok = np.isfinite(col)
        if ok.sum() >= 2:
            col[~ok] = np.interp(np.flatnonzero(~ok), np.flatnonzero(ok), col[ok])
        if k > 1 and len(col) >= k:
            pad = np.pad(col, (k // 2, k // 2), mode="edge")
            out[:, d] = np.convolve(pad, np.ones(k) / k, mode="valid")
    return out


def _crossing_x(xs: np.ndarray, ys: np.ndarray, level: float, rising: bool) -> float | None:
    """x where the path first crosses `level` (image y, smaller = higher)."""
    for i in range(1, len(ys)):
        a, b = ys[i - 1], ys[i]
        hit = (a > level >= b) if rising else (a < level <= b)
        if hit:
            t = (level - a) / (b - a) if b != a else 0.0
            return float(xs[i - 1] + t * (xs[i] - xs[i - 1]))
    return None


def analyze(landmarks: np.ndarray, address: int, top: int, impact: int,
            min_visibility: float = 0.5) -> dict:
    """landmarks: [frames, 33, 3] as (x_px, y_px, visibility). Returns the path verdict."""
    if not (0 <= address < top < impact < len(landmarks)):
        return {"verdict": "无法判断", "reason": "阶段顺序不对"}
    lm = landmarks.astype(float).copy()
    low = lm[:, :, 2] < min_visibility
    lm[low, 0:2] = np.nan

    hands = np.nanmean(lm[:, [L_WR, R_WR], 0:2], axis=1)
    if np.isfinite(hands[address:impact + 1]).all(axis=1).mean() < 0.7:
        return {"verdict": "无法判断", "reason": "手腕可见帧太少"}
    hands = _smooth(hands)

    a = lm[address]
    sh_mid = np.nanmean(a[[L_SH, R_SH], 0:2], axis=0)
    hip_mid = np.nanmean(a[[L_HIP, R_HIP], 0:2], axis=0)
    torso = float(np.linalg.norm(sh_mid - hip_mid))
    if not np.isfinite(torso) or torso < 1:
        return {"verdict": "无法判断", "reason": "准备姿势躯干不可见"}
    side = 1.0 if hands[address, 0] > hip_mid[0] else -1.0  # hands sit on the ball side of the hips

    y_addr, y_top = hands[address, 1], hands[top, 1]
    rise = y_addr - y_top
    if rise < 0.5 * torso:
        return {"verdict": "无法判断", "reason": "上杆幅度太小，可能不是沿目标线机位或阶段不准"}

    up_x, up_y = hands[address:top + 1, 0], hands[address:top + 1, 1]
    dn_x, dn_y = hands[top:impact + 1, 0], hands[top:impact + 1, 1]
    samples = []
    for frac in np.linspace(0.2, 0.8, 13):
        level = y_addr - frac * rise
        xu = _crossing_x(up_x, up_y, level, rising=True)
        xd = _crossing_x(dn_x, dn_y, level, rising=False)
        if xu is not None and xd is not None:
            samples.append((float(frac), (xd - xu) * side / torso))
    if len(samples) < 5:
        return {"verdict": "无法判断", "reason": "上下杆轨迹在同一高度上对不齐"}

    offsets = np.array([s[1] for s in samples])
    offset = float(np.median(offsets))
    if offset > PROVISIONAL_OUTSIDE:
        verdict = "外下倾向"
    elif offset < PROVISIONAL_INSIDE:
        verdict = "内下倾向"
    else:
        verdict = "路径基本正常"
    return {
        "verdict": verdict,
        "offset": round(offset, 3),
        "offset_by_height": [(round(f, 2), round(o, 3)) for f, o in samples],
        "torso_px": round(torso, 1),
        "side": int(side),
        "hands": hands.tolist(),
    }
