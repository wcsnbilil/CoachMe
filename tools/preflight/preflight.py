"""Retake checks before / during the analysis, with the full analysis's own refusal rules.

Two layers (CoachMeCore/Sources/CoachMeCore/Beta/Preflight.swift is a line-by-line port):

1. quick(): right after import, on a dozen or so poses sampled across the clip (seconds).
   Only what the full analysis would certainly refuse, or cannot run on:
     duration   too short to hold a swing
     person     no pose in most samples
     body       shoulders and hips not visible in most samples
     camera     not behind the golfer at all: even the narrowest standing sample is far wider than
                the full analysis allows at address (QUICK_CAMERA_WIDTH vs path_fault.MAX_LINE_WIDTH)
   Other people in the frame are reported (people > 1) but never refused: the full analysis does
   not refuse them either.

2. early_setup(): once SwingNet's phases are known (SwingNet runs first, it is light) and the pose
   pass has reached the top of the backswing, the full analysis's set-up refusals (trunk not visible,
   wrists not visible, jumpy key points, camera off the target line) with the same steps and
   constants as path_fault.analyze, on the frames seen so far. The analysis stops there on a refusal.
   When SwingNet finds no swing there is no early decision: the app retries SwingNet on a person crop
   made from the whole pose pass, as before.

Why not the camera rule on the sampled / first-pass poses: the full analysis measures the shoulder and
hip lines at SwingNet's address, a pass without SwingNet has to find its own address, and they are
often half a backswing apart. On GolfDB that agreed on 81-88% of clips; the same rule at SwingNet's
address agrees on 95-96% (tools/preflight/preflight_eval.py).
"""
from __future__ import annotations

import sys
import warnings
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
import path_fault  # noqa: E402

MIN_SECONDS = 1.0          # a full swing takes longer than this even in real time
QUICK_SAMPLES = 16         # poses sampled evenly across the clip for the quick layer
MIN_POSE_SHARE = 0.5       # samples with a pose at all
MIN_BODY_SHARE = 0.5       # ... of those, samples with a shoulder and a hip visible
QUICK_CAMERA_WIDTH = 0.45  # narrowest standing sample wider than this (torso lengths) = not down the line
MIN_VIS = 0.5
REFUSED = "无法判断"
LS, RS, LH, RH, LW, RW = 11, 12, 23, 24, 15, 16


def sample_indices(n: int, count: int = QUICK_SAMPLES) -> list[int]:
    """Frames the quick layer looks at: evenly spaced, first and last included."""
    if n <= count:
        return list(range(n))
    return [int(round(i * (n - 1) / (count - 1))) for i in range(count)]


def quick(samples: np.ndarray, duration: float, people: int = 1) -> dict:
    """samples: (k, 33, 3) pixel x, y, visibility (NaN = no pose), from sample_indices.
    people: most poses seen in one sample (the detector run with room for two).
    -> {"ok", "reason": None | "duration" | "person" | "body" | "camera", "width", "people"}"""
    out = {"ok": True, "reason": None, "width": None, "people": people}
    if duration < MIN_SECONDS:
        return {**out, "ok": False, "reason": "duration"}
    k = len(samples)
    if k == 0:
        return {**out, "ok": False, "reason": "person"}
    vis = samples[:, :, 2] >= MIN_VIS
    posed = np.isfinite(samples[:, :, 0]).any(axis=1) & vis.any(axis=1)
    if posed.sum() < MIN_POSE_SHARE * k:
        return {**out, "ok": False, "reason": "person"}
    trunk = (vis[:, LS] | vis[:, RS]) & (vis[:, LH] | vis[:, RH])
    if (trunk & posed).sum() < MIN_BODY_SHARE * posed.sum():
        return {**out, "ok": False, "reason": "body"}
    # standing samples: both shoulders and both hips seen, hands below the hips (address, not the swing)
    widths = []
    for f in range(k):
        p = samples[f]
        if not all(vis[f, j] for j in (LS, RS, LH, RH)):
            continue
        sh = (p[LS, :2] + p[RS, :2]) / 2
        hip = (p[LH, :2] + p[RH, :2]) / 2
        torso = float(np.hypot(*(sh - hip)))
        hands = [p[j, 1] for j in (LW, RW) if vis[f, j]]
        if torso < 1 or not hands or np.mean(hands) < hip[1]:
            continue
        widths.append(max(abs(p[LS, 0] - p[RS, 0]), abs(p[LH, 0] - p[RH, 0])) / torso)
    if widths:
        out["width"] = round(float(min(widths)), 3)
        if min(widths) > QUICK_CAMERA_WIDTH:
            return {**out, "ok": False, "reason": "camera"}
    return out


def early_frames(address: int, top: int, impact: int) -> int:
    """How many frames (from the clip start) early_setup needs: the top plus the smoothing margin."""
    k = path_fault._odd((impact - address) / 20)
    return top + k + 3


def early_setup(landmarks: np.ndarray, address: int, top: int, impact: int, min_visibility: float = 0.5) -> str | None:
    """path_fault.analyze's refusals up to and including the camera check, on frames [0, early_frames).
    The visibility / jump shares are over address..impact in the full analysis; here the frames after
    the top count as good, so this leans towards carrying on. The hip "home" of pose_glitches and the
    smoothing near the last frame only see frames up to the top, the one place the numbers can differ
    from the full analysis. Returns the refusal reason, or None = carry on."""
    if not (0 <= address < top < impact):
        return "阶段顺序不对"
    k = path_fault._odd((impact - address) / 20)
    h = max(2, k // 2)
    seen = min(len(landmarks), early_frames(address, top, impact))
    if seen <= top:
        return None
    lm = landmarks[:seen].astype(float).copy()
    lm[~(lm[:, :, 2] >= min_visibility), 0:2] = np.nan

    def anchors(f: int):
        body = path_fault.body_at(lm, f, 0, top - 1, h)
        sh = np.nanmean(body[[path_fault.L_SH, path_fault.R_SH]], axis=0)
        hip = np.nanmean(body[[path_fault.L_HIP, path_fault.R_HIP]], axis=0)
        return body, float(np.linalg.norm(sh - hip))

    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        body, torso = anchors(address)
    if not np.isfinite(torso) or torso < 1:
        return "准备姿势躯干不可见"
    raw = path_fault.hand_track(lm, torso)
    span, rest = impact - address + 1, impact - top
    if (np.isfinite(raw[address:top + 1]).all(axis=1).sum() + rest) / span < 0.7:
        return "手腕可见帧太少"
    raw[path_fault.pose_glitches(lm, raw, address, min(impact, seen - 1), torso)] = np.nan
    raw = path_fault.despike(raw, torso)
    if (np.isfinite(raw[address:top + 1]).all(axis=1).sum() + rest) / span < 0.7:
        return "关键点跳动太多"
    hands = path_fault._smooth(raw, k)
    f = path_fault.still_address(hands, address, top)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        b2, t2 = anchors(f)
    if np.isfinite(t2) and t2 >= 1:
        body, torso = b2, t2
    cam = path_fault.camera_check(body, torso)
    widest = max((v for v in cam.values() if np.isfinite(v)), default=np.nan)
    return "机位偏离目标线（肩/髋线太宽）" if widest > path_fault.MAX_LINE_WIDTH else None
