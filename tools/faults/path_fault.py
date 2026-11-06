"""Prototype: over-the-top (外下) / too-inside (内下) from a down-the-line video.

Python first, Swift later. Uses only 2D MediaPipe landmarks plus three phase
frames (address, top, impact).

Signal (down-the-line camera): at the same hand height, compare where the hands
are on the way down with where they were on the way up.

    offset = (x_down - x_up) * side / torso_length

offset > 0: hands come down outside (toward the ball) of the backswing path,
            the classic over-the-top loop
offset < 0: hands come down inside / behind the backswing path (too inside)

`side` is +1 when the ball is at larger image x than the golfer's hips, so a
left-handed golfer (mirror image) gets the same sign convention.

This is a hand-path proxy. The club itself is not tracked, so it measures the
loop of the hands, not the clubhead path.

v2 (after the first GolfDB run):
- hand track: frames where the two wrists are far apart (a MediaPipe miss or a
  wrist landing on the elbow) or only one wrist is visible are dropped instead
  of letting the average jump; then a Hampel filter removes the remaining
  spikes and a moving average smooths. Both windows scale with the number of
  frames in the swing, so a 30 fps clip and its slow-motion copy are smoothed
  over the same stretch of the swing.
- crossings: the median of every crossing at a height, not the first one,
  so one zig-zag no longer decides the sample.
- side: majority vote of four cues (hands, nose, shoulders vs hips at address,
  and where the hands go at the top), not the hands alone.
- camera check: in a true down-the-line view the shoulders and hips are seen
  end-on at address. A wide shoulder/hip line means the camera is off the
  target line, and the clip is refused.
- thresholds: centre and band come from a calibration file built from pro
  swings (calibrate.py), so a typical tour swing reads 路径基本正常.
"""

from __future__ import annotations

import warnings

import numpy as np

# MediaPipe pose indices
NOSE, L_SH, R_SH, L_HIP, R_HIP, L_WR, R_WR = 0, 11, 12, 23, 24, 15, 16

# Used when no calibration file is passed: calibrate.py on the first 200 GolfDB
# down-the-line swings (82 golfers, 197 offsets), 80% of golfers inside the band.
DEFAULT_CALIBRATION = {"center": 0.065, "outside": 0.246, "inside": -0.117, "source": "golfdb_dtl_first200"}

# Wrists further apart than this (in torso lengths) are not both on the grip.
MAX_WRIST_GAP = 0.6
# Shoulder or hip line wider than this at address (in torso lengths) = off-axis camera.
# GolfDB DTL: median 0.08, 90th percentile 0.18, widest 0.33 (golfdb_50, the clip
# judged "camera too close" by eye). Catches clearly off-axis clips only.
MAX_LINE_WIDTH = 0.3


def _odd(n: float, lo: int = 3) -> int:
    k = max(lo, int(round(n)))
    return k if k % 2 else k + 1


def _interp_nan(col: np.ndarray) -> np.ndarray:
    col = col.copy()
    ok = np.isfinite(col)
    if ok.sum() >= 2:
        col[~ok] = np.interp(np.flatnonzero(~ok), np.flatnonzero(ok), col[ok])
    return col


def _hampel(col: np.ndarray, k: int, n_sigma: float = 3.0) -> np.ndarray:
    """Replace points far from the running median by that median (spike removal)."""
    out = col.copy()
    h = k // 2
    for i in range(len(col)):
        win = col[max(0, i - h): i + h + 1]
        win = win[np.isfinite(win)]
        if len(win) < 3 or not np.isfinite(col[i]):
            continue
        med = np.median(win)
        mad = 1.4826 * np.median(np.abs(win - med))
        if mad > 0 and abs(col[i] - med) > n_sigma * mad:
            out[i] = med
    return out


def _smooth(track: np.ndarray, k: int) -> np.ndarray:
    """Hampel filter, NaN interpolation, then a k-frame moving average (edge padded)."""
    out = track.copy()
    for d in range(out.shape[1]):
        col = _interp_nan(_hampel(out[:, d], k))
        if k > 1 and len(col) >= k and np.isfinite(col).all():
            pad = np.pad(col, (k // 2, k // 2), mode="edge")
            col = np.convolve(pad, np.ones(k) / k, mode="valid")
        out[:, d] = col
    return out


def hand_track(lm: np.ndarray, torso: float) -> np.ndarray:
    """Midpoint of the two wrists per frame, NaN where it can't be trusted.

    The midpoint does not change if MediaPipe swaps the left/right labels, so a
    clean swap is harmless. What breaks the path is a swap where one wrist lands
    somewhere else (often the elbow): the wrists are then far apart, so those
    frames are dropped and filled from their neighbours. A frame with only one
    wrist uses that wrist (both are on the grip); if it is wrong it shows up as a
    spike and the Hampel filter in _smooth replaces it.
    """
    lw, rw = lm[:, L_WR, 0:2], lm[:, R_WR, 0:2]
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        hands = np.nanmean(np.stack([lw, rw]), axis=0)  # one wrist is fine: they share the grip
    gap = np.linalg.norm(lw - rw, axis=1)
    hands[gap > MAX_WRIST_GAP * torso] = np.nan  # NaN gap (one wrist) is kept, Hampel catches spikes
    return hands


def _crossings_x(xs: np.ndarray, ys: np.ndarray, level: float, rising: bool) -> list[float]:
    """x at every crossing of `level` (image y, smaller = higher) in the given direction."""
    out = []
    for i in range(1, len(ys)):
        a, b = ys[i - 1], ys[i]
        hit = (a > level >= b) if rising else (a < level <= b)
        if hit:
            t = (level - a) / (b - a) if b != a else 0.0
            out.append(float(xs[i - 1] + t * (xs[i] - xs[i - 1])))
    return out


def _sign(v: float) -> int:
    return 0 if not np.isfinite(v) or v == 0 else (1 if v > 0 else -1)


def detect_side(lm: np.ndarray, hands: np.ndarray, address: int, top: int) -> tuple[int, dict]:
    """+1 if the ball is at larger image x than the hips. Majority of four cues."""
    a = lm[address]
    hip = np.nanmean(a[[L_HIP, R_HIP], 0:2], axis=0)[0]
    sh = np.nanmean(a[[L_SH, R_SH], 0:2], axis=0)[0]
    votes = {
        "hands": _sign(hands[address, 0] - hip),     # hands hang toward the ball
        "nose": _sign(a[NOSE, 0] - hip),             # head is over the ball
        "shoulders": _sign(sh - hip),                # spine tilts toward the ball
        "top": _sign(hands[address, 0] - hands[top, 0]),  # hands go back toward the body at the top
    }
    total = sum(votes.values())
    return (0 if total == 0 else (1 if total > 0 else -1)), votes


def camera_check(lm: np.ndarray, address: int, torso: float) -> dict:
    """How wide the shoulder and hip lines look at address, in torso lengths."""
    a = lm[address]
    return {
        "shoulder_width": round(float(abs(a[L_SH, 0] - a[R_SH, 0]) / torso), 3),
        "hip_width": round(float(abs(a[L_HIP, 0] - a[R_HIP, 0]) / torso), 3),
    }


def classify(offset: float, cal: dict) -> str:
    if offset > cal["outside"]:
        return "外下倾向"
    if offset < cal["inside"]:
        return "内下倾向"
    return "路径基本正常"


def analyze(landmarks: np.ndarray, address: int, top: int, impact: int,
            min_visibility: float = 0.5, calibration: dict | None = None,
            max_line_width: float = MAX_LINE_WIDTH) -> dict:
    """landmarks: [frames, 33, 3] as (x_px, y_px, visibility). Returns the path verdict."""
    cal = calibration or DEFAULT_CALIBRATION
    if not (0 <= address < top < impact < len(landmarks)):
        return {"verdict": "无法判断", "reason": "阶段顺序不对"}
    lm = landmarks.astype(float).copy()
    low = ~(lm[:, :, 2] >= min_visibility)
    lm[low, 0:2] = np.nan

    a = lm[address]
    sh_mid = np.nanmean(a[[L_SH, R_SH], 0:2], axis=0)
    hip_mid = np.nanmean(a[[L_HIP, R_HIP], 0:2], axis=0)
    torso = float(np.linalg.norm(sh_mid - hip_mid))
    if not np.isfinite(torso) or torso < 1:
        return {"verdict": "无法判断", "reason": "准备姿势躯干不可见"}

    cam = camera_check(lm, address, torso)
    widest = max((v for v in cam.values() if np.isfinite(v)), default=np.nan)
    if widest > max_line_width:
        return {"verdict": "无法判断", "reason": "机位偏离目标线（肩/髋线太宽）", "camera": cam,
                "torso_px": round(torso, 1)}

    raw = hand_track(lm, torso)
    if np.isfinite(raw[address:impact + 1]).all(axis=1).mean() < 0.7:
        return {"verdict": "无法判断", "reason": "手腕可见帧太少", "camera": cam}
    k = _odd((impact - address) / 20)
    hands = _smooth(raw, k)

    side, votes = detect_side(lm, hands, address, top)
    if side == 0:
        return {"verdict": "无法判断", "reason": "分不清左右手（线索打平）", "side_votes": votes, "camera": cam}

    y_addr, y_top = hands[address, 1], hands[top, 1]
    rise = y_addr - y_top
    if rise < 0.5 * torso:
        return {"verdict": "无法判断", "reason": "上杆幅度太小，可能不是沿目标线机位或阶段不准", "camera": cam}

    up_x, up_y = hands[address:top + 1, 0], hands[address:top + 1, 1]
    dn_x, dn_y = hands[top:impact + 1, 0], hands[top:impact + 1, 1]
    samples = []
    for frac in np.linspace(0.2, 0.8, 13):
        level = y_addr - frac * rise
        xu = _crossings_x(up_x, up_y, level, rising=True)
        xd = _crossings_x(dn_x, dn_y, level, rising=False)
        if xu and xd:
            samples.append((float(frac), (np.median(xd) - np.median(xu)) * side / torso))
    if len(samples) < 5:
        return {"verdict": "无法判断", "reason": "上下杆轨迹在同一高度上对不齐", "camera": cam}

    offset = float(np.median([s[1] for s in samples]))
    return {
        "verdict": classify(offset, cal),
        "offset": round(offset, 3),
        "offset_by_height": [(round(f, 2), round(o, 3)) for f, o in samples],
        "torso_px": round(torso, 1),
        "side": int(side),
        "side_votes": votes,
        "camera": cam,
        "smooth_frames": k,
        "dropped_frames": int((~np.isfinite(raw[address:impact + 1]).all(axis=1)).sum()),
        "calibration": cal.get("source", "file"),
        "hands": hands.tolist(),
    }
