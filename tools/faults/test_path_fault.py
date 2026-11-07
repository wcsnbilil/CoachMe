"""Synthetic checks for path_fault.py:  python -m pytest tools/faults  (or run directly)."""

from __future__ import annotations

import numpy as np

import path_fault as pf


def make_swing(loop: float = 0.0, frames: int = 60, lefty: bool = False, wrist_gap: float = 0.1,
               shoulder_width: float = 0.15, seed: int | None = None, noise: float = 0.0,
               takeaway: float = 0.0) -> tuple[np.ndarray, int, int, int]:
    """A right-handed DTL swing in pixels: torso 100 px, ball at larger x.

    The hands go up along one line and come down along another, `loop` torso
    lengths further toward the ball (positive = over the top). `takeaway`
    bends the backswing the same way (negative = flat, inside takeaway).
    """
    rng = np.random.default_rng(seed)
    address, top, impact = int(frames * 0.1), int(frames * 0.6), int(frames * 0.85)
    lm = np.zeros((frames, 33, 3))
    lm[:, :, 2] = 1.0
    hip, torso = np.array([200.0, 300.0]), 100.0
    sh = hip + [30.0, -torso * 0.95]          # bent toward the ball
    sh_off = np.array([shoulder_width * torso / 2, 0])
    lm[:, pf.L_HIP, :2], lm[:, pf.R_HIP, :2] = hip - sh_off * 0.8, hip + sh_off * 0.8
    lm[:, pf.L_SH, :2], lm[:, pf.R_SH, :2] = sh - sh_off, sh + sh_off
    lm[:, pf.NOSE, :2] = sh + [40.0, -30.0]
    addr_hand, top_hand = np.array([260.0, 330.0]), np.array([180.0, 130.0])
    hands = np.zeros((frames, 2))
    for f in range(frames):
        if f <= address:
            hands[f] = addr_hand
        elif f <= top:
            t = (f - address) / (top - address)
            hands[f] = addr_hand + (top_hand - addr_hand) * t
            hands[f, 0] += takeaway * torso * np.sin(np.pi * t)
        else:
            t = min(1.0, (f - top) / (impact - top))
            hands[f] = top_hand + (addr_hand - top_hand) * t
            hands[f, 0] += loop * torso * np.sin(np.pi * t)  # bulge toward the ball, back at impact
    hands += rng.normal(0, noise, hands.shape) if noise else 0
    half = np.array([wrist_gap * torso / 2, 0])
    lm[:, pf.L_WR, :2], lm[:, pf.R_WR, :2] = hands - half, hands + half
    if lefty:  # mirror the picture
        lm[:, :, 0] = 400.0 - lm[:, :, 0]
    return lm, address, top, impact


def test_over_the_top_and_inside():
    assert pf.analyze(*make_swing(loop=0.6))["verdict"] == "外下过度"
    assert pf.analyze(*make_swing(loop=-0.4))["verdict"] == "内下过度"
    assert pf.analyze(*make_swing(loop=0.0))["verdict"] == "路径在职业范围内"


def test_lefty_mirror_gives_same_offset():
    r, l = pf.analyze(*make_swing(loop=0.4)), pf.analyze(*make_swing(loop=0.4, lefty=True))
    assert r["side"] == 1 and l["side"] == -1
    assert abs(r["offset"] - l["offset"]) < 1e-6


def test_wrist_label_swap_is_harmless():
    lm, a, t, i = make_swing(loop=0.4)
    base = pf.analyze(lm, a, t, i)["offset"]
    lm[a + 5:a + 15, [pf.L_WR, pf.R_WR]] = lm[a + 5:a + 15, [pf.R_WR, pf.L_WR]]
    assert pf.analyze(lm, a, t, i)["offset"] == base


def test_wrist_jumping_to_elbow_is_dropped():
    lm, a, t, i = make_swing(loop=0.0, frames=120)
    base = pf.analyze(lm, a, t, i)["offset"]
    for f in range(t + 4, i - 4, 7):  # left wrist lands 80 px toward the ball on some downswing frames
        lm[f, pf.L_WR, 0] += 80
    r = pf.analyze(lm, a, t, i)
    assert r["dropped_frames"] > 0 and abs(r["offset"] - base) < 0.03, r["offset"]


def test_single_frame_spike_is_removed():
    lm, a, t, i = make_swing(loop=0.0, frames=120)
    lm[t + 10, pf.R_WR, 2] = 0.0          # one wrist hidden ...
    lm[t + 10, pf.L_WR, 0] += 40          # ... and the other mislocated
    assert pf.analyze(lm, a, t, i)["verdict"] == "路径在职业范围内"


def test_slow_motion_copy_agrees():
    fast = pf.analyze(*make_swing(loop=0.25, frames=40, noise=1.5, seed=1))
    slow = pf.analyze(*make_swing(loop=0.25, frames=160, noise=1.5, seed=2))
    assert slow["smooth_frames"] > fast["smooth_frames"]
    assert abs(fast["offset"] - slow["offset"]) < 0.05, (fast["offset"], slow["offset"])


def test_off_axis_camera_is_refused():
    r = pf.analyze(*make_swing(shoulder_width=0.9))
    assert r["verdict"] == "无法判断" and "机位" in r["reason"]


def test_calibration_moves_the_centre():
    wide = {"center": 0.0, "outside": 0.6, "inside": -0.6, "source": "test"}
    tight = {"center": 0.0, "outside": 0.1, "inside": -0.6, "source": "test"}
    assert pf.analyze(*make_swing(loop=0.0))["verdict"] == "路径在职业范围内"
    assert pf.analyze(*make_swing(loop=0.4), calibration=wide)["verdict"] == "路径在职业范围内"
    assert pf.analyze(*make_swing(loop=0.4), calibration=tight)["verdict"] == "外下过度"


def test_vertical_reference_line_is_refused():
    lm, a, t, i = make_swing()
    r = pf.analyze(lm, a, t, i)
    assert 5 < r["ref_angle"] < 30
    assert pf.analyze(lm, a, t, i, min_ref_angle=r["ref_angle"] + 1)["verdict"] == "无法判断"


def test_inside_takeaway_is_not_over_the_top():
    """Flat, inside takeaway + normal downswing (Tim Clark style): v2's loop was
    big, v3's downswing offset must not move."""
    normal = pf.analyze(*make_swing(loop=0.0))
    flat = pf.analyze(*make_swing(loop=0.0, takeaway=-0.5))
    assert flat["loop"] > 0.3 and flat["backswing_offset"] < normal["backswing_offset"] - 0.3
    assert abs(flat["offset"] - normal["offset"]) < 0.02
    assert flat["verdict"] == "路径在职业范围内"


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
