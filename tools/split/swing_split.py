"""Split a long clip into single swings from pose landmarks alone (hands' height).

The app runs SwingNet + the path analyzer on one swing at a time, so a video with several swings is
first cut into windows here; the user then picks a swing (default: the last one).

Rule (all lengths in torso units = median shoulder-mid to hip-mid distance):
  top     = local highest hands, at least near shoulder height (hands above shoulders - TOP_BELOW)
  address = lowest hands since the previous swing, last frame still at that height before the top
            (hands near the hips, and at least REST_S after the previous impact: a finish followed
            by lowering the club is not a swing)
  impact  = after the top, the hands come back to the address height (+ IMPACT_TOL) near the
            address x, and the downswing is not slower than DOWN_RATIO x the backswing
A clip with 0 or 1 swings found is analysed whole, exactly as before (no change for single swings).
Below 30 fps the frame counts shrink with the rate: the app's first pass samples about 15 fps.

CoachMeCore/Sources/CoachMeCore/Split/SwingSplitter.swift is a line-by-line port; CI checks both
give the same windows on tools/split/fixtures/split_parity.json.

usage: python tools/split/swing_split.py landmarks.npy [--fps 30]
"""
from __future__ import annotations

import argparse
import json
import sys

import numpy as np

LW, RW, LS, RS, LH, RH = 15, 16, 11, 12, 23, 24
MIN_VIS = 0.5
TOP_BELOW = 0.1        # top: hands may sit this far below the shoulder line (short / compact tops)
ADDRESS_STILL = 0.05   # address: last frame within this of the lowest hands before the top
ADDRESS_MAX = 0.1      # address hands must be below hips + this (rejects tops measured from the chest)
IMPACT_TOL = 0.45      # impact: hands back within this of the address height
IMPACT_X = 0.6         # ... and within this horizontally of the address hands
DOWN_RATIO = 0.9       # downswing frames <= ratio x backswing frames (pros 0.05-0.72 on GolfDB)
MIN_BACK = 4           # backswing frames at least
REST_S = 1.0           # next address at least this long after the previous impact (kills finish -> lower)
PAD_BEFORE_S = 1.0     # window starts this long before address (SwingNet needs some address)
PAD_AFTER_S = 1.5      # ... and ends this long after impact (finish)
# Slow-motion files whose timeline is stretched (iPhone slo-mo exported at 30 fps): the swing itself is
# found the same way (the rule is about shape, not speed), but one second of padding would be a
# fraction of a second of real motion. A swing that takes longer than SLOW_SWING_S from address to
# impact gets its padding stretched by duration / NORMAL_SWING_S.
SLOW_SWING_S = 2.0     # real-time swings: 0.6-1.4 s address -> impact
NORMAL_SWING_S = 1.0


def _fill(v: np.ndarray) -> np.ndarray:
    v = v.copy()
    ok = np.isfinite(v)
    if ok.sum() < 2:
        return v
    v[~ok] = np.interp(np.flatnonzero(~ok), np.flatnonzero(ok), v[ok])
    return v


def smooth(v: np.ndarray, k: int) -> np.ndarray:
    """Gaps linearly filled, then a centred box filter of odd width k with edge padding."""
    v = _fill(v)
    k = max(1, k | 1)
    pad = np.pad(v, k // 2, mode="edge")
    return np.convolve(pad, np.ones(k) / k, mode="valid")


def _mean2(x: np.ndarray, a: int, b: int, vis: float = MIN_VIS) -> np.ndarray:
    """Mean of two joints per frame using only visible ones (NaN when neither is)."""
    out = np.full((len(x), 2), np.nan)
    for i in range(len(x)):
        pts = [x[i, j, :2] for j in (a, b) if x[i, j, 2] >= vis and np.isfinite(x[i, j, 0])]
        if pts:
            out[i] = np.mean(pts, 0)
    return out


def find_swings(lm: np.ndarray, fps: float = 30.0) -> list[tuple[int, int, int]]:
    """(address, top, impact) frame triples, in time order. lm: (frames, 33, 3) x, y, visibility."""
    n = len(lm)
    if n < 10:
        return []
    # hands: both wrists whenever a pose was found (one hidden wrist at the top would otherwise jump
    # the mean by half the wrist spacing)
    hands = _mean2(lm, LW, RW, vis=0.0)
    sh = _mean2(lm, LS, RS)
    hip = _mean2(lm, LH, RH)
    d = np.linalg.norm(sh - hip, axis=1)
    d = d[np.isfinite(d)]
    if len(d) == 0:
        return []
    torso = float(np.median(d))
    if torso < 10 or not np.isfinite(hands[:, 1]).any() or not np.isfinite(sh[:, 1]).any() \
            or not np.isfinite(hip[:, 1]).any():
        return []
    r = max(1, int(round(fps / 30.0)))  # frame counts below are tuned at 30 fps
    # below 30 fps (the app's quick first pass samples about 15 fps) the counts shrink with the rate
    q = min(1.0, fps / 30.0)

    def frames(count: int, least: int) -> int:
        return max(least, int(round(count * r * q)))

    ks, kb = max(1, int(3 * r * q)), max(3, int(9 * r * q))  # smoothing never wider in time than at 30 fps
    hy, hx = smooth(hands[:, 1], ks), smooth(hands[:, 0], ks)
    shy, hipy = smooth(sh[:, 1], kb), smooth(hip[:, 1], kb)
    win, min_back = frames(5, 2), frames(MIN_BACK, 2)
    near = frames(3, 2)

    def high(i: int) -> bool:
        return hy[i] < shy[i] + TOP_BELOW * torso

    out: list[tuple[int, int, int]] = []
    i = 1
    while i < n - 1:
        if not (high(i) and hy[i] <= hy[max(0, i - win):i + win + 1].min()):
            i += 1
            continue
        j = i
        while j < n and high(j):
            j += 1
        top = i + int(np.argmin(hy[i:j]))
        lo = out[-1][2] + int(round(REST_S * fps)) if out else 0
        if top - lo < min_back + 2:
            i = top + 1
            continue
        jlow = lo + int(np.argmax(hy[lo:top]))
        level = hy[jlow]
        ad = max(f for f in range(jlow, top) if hy[f] >= level - ADDRESS_STILL * torso)
        back = top - ad
        if back < min_back or not (hy[ad] > hipy[ad] - ADDRESS_MAX * torso):
            i = top + 1
            continue
        k = top + 1
        limit = top + int(DOWN_RATIO * back) + 1
        while k < n and k <= limit and hy[k] < hy[ad] - IMPACT_TOL * torso:
            k += 1
        # the hands' x is checked over the next ~0.1 s too: at a low frame rate the first frame back at
        # address height can still be well short of the ball
        if k >= n or k > limit or np.abs(hx[k:k + near + 1] - hx[ad]).min() > IMPACT_X * torso:
            i = top + 1
            continue
        # impact = hands' lowest point before they rise again for the finish
        m = k
        cap = max(frames(3, 1), (k - top) // 2)
        while m + 1 < n and not high(m + 1) and m - k < cap:
            m += 1
        imp = top + int(np.argmax(hy[top:m + 1]))
        out.append((ad, top, imp))
        i = max(imp, j) + 1
    return out


def windows(swings: list[tuple[int, int, int]], n: int, fps: float, single: bool = False) -> list[tuple[int, int]]:
    """[start, end) frame windows for each swing; empty when the clip should be analysed whole
    (fewer than 2 swings, or none when `single`: the app cuts a long clip down to its one swing)."""
    if len(swings) < (1 if single else 2):
        return []
    out = []
    for idx, (ad, _, imp) in enumerate(swings):
        took = (imp - ad) / fps
        slow = took / NORMAL_SWING_S if took > SLOW_SWING_S else 1.0
        pre, post = int(round(PAD_BEFORE_S * fps * slow)), int(round(PAD_AFTER_S * fps * slow))
        start = max(0, ad - pre)
        end = min(n, imp + post + 1)
        if idx > 0:  # never reach back into the previous swing
            start = max(start, swings[idx - 1][2] + 1)
        if idx + 1 < len(swings):
            end = min(end, swings[idx + 1][0])
        out.append((start, end))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("landmarks", help=".npy (frames, 33, 3) pixel x, y, visibility")
    ap.add_argument("--fps", type=float, default=30.0)
    a = ap.parse_args()
    lm = np.load(a.landmarks)
    s = find_swings(lm, a.fps)
    json.dump({"swings": s, "windows": windows(s, len(lm), a.fps)}, sys.stdout)
    print()


if __name__ == "__main__":
    main()
