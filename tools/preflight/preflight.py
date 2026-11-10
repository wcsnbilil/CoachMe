"""Quick check right after import: is this video worth the full analysis?

The app already samples a long clip at about 15 fps to find the swings (SwingAnalyzer.scout). The
same sparse landmarks answer the retake questions in seconds, before SwingNet and the full-rate
pose pass run:

  duration      too short to hold a swing
  person        no pose in most frames (nobody there, too far, too dark)
  whole body    shoulders / hips / wrists hidden in most frames
  camera        not behind the golfer on the target line (shoulder / hip line too wide at address)

The camera and wrist checks are not new rules: the last swing the splitter finds is run through
path_fault.analyze on the sparse landmarks, and only its set-up refusals (SETUP) stop the import.
Tracking refusals need the full-rate pass and are left to it. No swing found = no opinion (pass):
SwingNet may still find one.

CoachMeCore/Sources/CoachMeCore/Beta/Preflight.swift is a line-by-line port.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
sys.path.insert(0, str(ROOT / "tools" / "split"))
import path_fault  # noqa: E402
import swing_split  # noqa: E402

MIN_SECONDS = 1.0        # a full swing takes longer than this even in real time
MIN_POSE_SHARE = 0.5     # frames with a pose at all
MIN_BODY_SHARE = 0.5     # ... of those, frames with both shoulders-or-hips pairs visible
MIN_VIS = 0.5
SETUP_TOL = 0.03         # set-up frame: hands within this (torso lengths) of where they rest longest
SETUP_LOOKBACK = 3       # ... searched this many backswing lengths before the splitter's address
REFUSED = "无法判断"
# path_fault refusals by what the golfer can do about them
CAMERA = {"机位偏离目标线（肩/髋线太宽）", "参考线接近竖直，机位可能偏或俯拍", "上杆幅度太小，可能不是沿目标线机位或阶段不准",
          "准备姿势肩膀不在双手上方"}
BODY = {"准备姿势躯干不可见", "手腕可见帧太少"}
TRACKING = {"关键点跳动太多", "下杆有一段双手追踪丢失或乱跳"}
# needs more frames than the sparse pass has: never a reason to stop the import
SPARSE_ONLY = {"下杆轨迹在参考高度上取不到足够的点", "阶段顺序不对", "分不清左右手（线索打平）"}
POLICIES = {
    "setup": {"机位偏离目标线（肩/髋线太宽）"} | BODY,
    "setup+tracking": {"机位偏离目标线（肩/髋线太宽）"} | BODY | TRACKING,
    "all_but_sparse": CAMERA | BODY | TRACKING,
    "all": CAMERA | BODY | TRACKING | SPARSE_ONLY,
}


def setup_frame(lm: np.ndarray, address: int, top: int, lo: int = 0, how: str = "mode", tol: float = SETUP_TOL) -> int:
    """The splitter's address is the last frame with the hands still low, which is well into the
    takeaway (the hands first move back, not up), so the shoulders have started to turn and the
    camera check reads wide. Step back to where the golfer actually stood.

    mode:  the hand position that has the most frames within `tol` torso lengths of it, over the
           SETUP_LOOKBACK backswing lengths before `address`; the last frame that close to it.
    speed: path_fault.still_address without its walk-back limit.
    split: the splitter's frame as is."""
    if how == "split":
        return address
    hands = swing_split._mean2(lm, swing_split.LW, swing_split.RW, vis=0.0)
    if how == "speed":
        hands = np.stack([swing_split.smooth(hands[:, 0], 3), swing_split.smooth(hands[:, 1], 3)], 1)
        speed = np.hypot(*(hands[1:top + 1] - hands[:top]).T)
        still = 0.1 * float(np.mean(speed[address:top]))
        for f in range(address, lo - 1, -1):
            if speed[f] <= still:
                return f
        return address
    sh = swing_split._mean2(lm, swing_split.LS, swing_split.RS)
    hip = swing_split._mean2(lm, swing_split.LH, swing_split.RH)
    d = np.linalg.norm(sh - hip, axis=1)
    torso = float(np.median(d[np.isfinite(d)]))
    a = max(lo, address - SETUP_LOOKBACK * (top - address))
    seg = hands[a:address + 1]
    ok = np.isfinite(seg).all(axis=1)
    if ok.sum() < 2:
        return address
    dist = np.linalg.norm(seg[:, None] - seg[None], axis=2)
    count = np.where(ok, (dist <= tol * torso).sum(axis=1), -1)
    best = int(np.flatnonzero(count == count.max())[-1])
    return a + int(np.flatnonzero(dist[best] <= tol * torso)[-1])


def sparse_analysis(lm: np.ndarray, fps: float, how: str = "mode", tol: float = SETUP_TOL) -> tuple[int, dict | None]:
    """(swings found, path_fault result of the last one or None)."""
    swings = swing_split.find_swings(lm, fps)
    if not swings:
        return 0, None
    ad, top, imp = swings[-1]
    lo = swings[-2][2] + 1 if len(swings) > 1 else 0
    return len(swings), path_fault.analyze(lm, setup_frame(lm, ad, top, lo, how, tol), top, imp)


def basics(lm: np.ndarray, fps: float, duration: float | None = None) -> dict | None:
    """Duration / person / whole body. None = fine."""
    n = len(lm)
    seconds = duration if duration is not None else n / fps
    if seconds < MIN_SECONDS or n < 10:
        return {"ok": False, "reason": "duration", "detail": "视频太短", "swings": 0}
    posed = np.isfinite(lm[:, :, 0]).any(axis=1)
    if posed.mean() < MIN_POSE_SHARE:
        return {"ok": False, "reason": "person", "detail": "大部分画面里没有识别到人", "swings": 0}
    vis = lm[:, :, 2] >= MIN_VIS
    torso = (vis[:, 11] | vis[:, 12]) & (vis[:, 23] | vis[:, 24])
    if torso[posed].mean() < MIN_BODY_SHARE:
        return {"ok": False, "reason": "body", "detail": "大部分画面里看不到肩和髋", "swings": 0}
    return None


def check(lm: np.ndarray, fps: float, duration: float | None = None, how: str = "mode",
          policy: str = "setup", tol: float = SETUP_TOL) -> dict:
    """lm: (frames, 33, 3) pixel x, y, visibility at about 15 fps (NaN rows = no pose).
    -> {"ok", "reason": None | "duration" | "person" | "body" | "camera" | "tracking", "detail", "swings"}"""
    bad = basics(lm, fps, duration)
    if bad:
        return bad
    found, r = sparse_analysis(lm, fps, how, tol)
    if r is None:
        return {"ok": True, "reason": None, "detail": "没找到挥杆，交给完整分析", "swings": 0}
    why = r.get("reason", "") if r["verdict"] == REFUSED else ""
    stop = why in POLICIES[policy]
    kind = "camera" if why in CAMERA else "body" if why in BODY else "tracking"
    return {"ok": not stop, "reason": kind if stop else None, "detail": why if stop else "", "swings": found,
            "sparse_verdict": r["verdict"], "sparse_reason": why, "camera": r.get("camera")}
