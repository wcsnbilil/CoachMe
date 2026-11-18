"""Why does swing_split.find_swings find no (or too few) swings in a clip? Diagnostics only.

Walks the same candidate tops as find_swings (same constants, same order) and prints, for every
candidate, the step that rejected it, with the numbers behind that step. Then a count of reasons
over all files. Prints numbers only: no frames, no video.

  python tools/split/split_why.py <file.npy | folder> [...] [--fps 30] [--only-zero] [--quiet]

A folder is searched recursively for *.npy. The frame rate comes from --fps, else from a sibling
<name>.fps.json or <name>.json ("fps" key, or a bare number), else 30.

Reasons:
  no_pose         no shoulders / hips / hands, or torso < 10 px
  no_high         the hands are never at shoulder height (top rule): nothing to check
  rest            candidate top too close to the clip start or to the previous impact (REST_S)
  short_back      fewer than MIN_BACK frames from address to top
  address_high    the lowest hands before the top are not near the hips (address rule)
  slow_down       hands not back at address height within DOWN_RATIO x backswing frames
                  (the downswing took longer than the backswing: e.g. a speed-ramped slow-motion edit)
  clip_end        the clip ends before the hands come back down
  impact_x        hands back at address height but too far sideways from the address hands
  ok              accepted as a swing
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import swing_split as S  # noqa: E402


def fps_for(npy: Path, default: float | None) -> float:
    if default:
        return default
    stem = npy.name[:-4]
    for cand in (npy.with_name(stem + ".fps.json"), npy.with_name(stem + ".json")):
        if cand.exists():
            try:
                v = json.loads(cand.read_text(encoding="utf-8"))
                if isinstance(v, (int, float)):
                    return float(v)
                if isinstance(v, dict) and "fps" in v:
                    return float(v["fps"])
            except (ValueError, OSError):
                pass
    return 30.0


def diagnose(lm: np.ndarray, fps: float) -> tuple[list[dict], dict]:
    """Same walk as swing_split.find_swings; returns one record per candidate top, plus clip info."""
    n = len(lm)
    info = {"frames": n, "fps": fps}
    if n < 10:
        return [{"reason": "no_pose", "why": "fewer than 10 frames"}], info
    hands = S._mean2(lm, S.LW, S.RW, vis=0.0)
    sh = S._mean2(lm, S.LS, S.RS)
    hip = S._mean2(lm, S.LH, S.RH)
    d = np.linalg.norm(sh - hip, axis=1)
    d = d[np.isfinite(d)]
    info["pose_frac"] = round(float(np.isfinite(hands[:, 1]).mean()), 3)
    if len(d) == 0:
        return [{"reason": "no_pose", "why": "no shoulder+hip frame"}], info
    torso = float(np.median(d))
    info["torso_px"] = round(torso, 1)
    if torso < 10 or not np.isfinite(hands[:, 1]).any() or not np.isfinite(sh[:, 1]).any() \
            or not np.isfinite(hip[:, 1]).any():
        return [{"reason": "no_pose", "why": f"torso {torso:.1f} px or no hands"}], info
    r = max(1, int(round(fps / 30.0)))
    q = min(1.0, fps / 30.0)

    def frames(count: int, least: int) -> int:
        return max(least, int(round(count * r * q)))

    ks, kb = max(1, int(3 * r * q)), max(3, int(9 * r * q))
    hy, hx = S.smooth(hands[:, 1], ks), S.smooth(hands[:, 0], ks)
    shy, hipy = S.smooth(sh[:, 1], kb), S.smooth(hip[:, 1], kb)
    win, min_back = frames(5, 2), frames(S.MIN_BACK, 2)
    near = frames(3, 2)
    # how high the hands get, in torso units above the shoulder line (positive = above)
    info["max_hands_above_shoulder"] = round(float(np.nanmax((shy - hy) / torso)), 2)

    def high(i: int) -> bool:
        return hy[i] < shy[i] + S.TOP_BELOW * torso

    recs: list[dict] = []
    accepted: list[tuple[int, int, int]] = []
    i = 1
    while i < n - 1:
        if not (high(i) and hy[i] <= hy[max(0, i - win):i + win + 1].min()):
            i += 1
            continue
        j = i
        while j < n and high(j):
            j += 1
        top = i + int(np.argmin(hy[i:j]))
        rec = {"top": top}
        lo = accepted[-1][2] + int(round(S.REST_S * fps)) if accepted else 0
        if top - lo < min_back + 2:
            rec.update(reason="rest", why=f"top {top} - start {lo} < {min_back + 2}")
            recs.append(rec)
            i = top + 1
            continue
        jlow = lo + int(np.argmax(hy[lo:top]))
        level = hy[jlow]
        ad = max(f for f in range(jlow, top) if hy[f] >= level - S.ADDRESS_STILL * torso)
        back = top - ad
        rec.update(address=ad, back=back)
        if back < min_back:
            rec.update(reason="short_back", why=f"backswing {back} frames < {min_back}")
            recs.append(rec)
            i = top + 1
            continue
        above_hip = (hipy[ad] - hy[ad]) / torso
        if not (hy[ad] > hipy[ad] - S.ADDRESS_MAX * torso):
            rec.update(reason="address_high",
                       why=f"address hands {above_hip:.2f} torso above hips (max {S.ADDRESS_MAX})")
            recs.append(rec)
            i = top + 1
            continue
        k = top + 1
        limit = top + int(S.DOWN_RATIO * back) + 1
        while k < n and k <= limit and hy[k] < hy[ad] - S.IMPACT_TOL * torso:
            k += 1
        # where the hands really get back to address height (no frame limit), for the slow_down numbers
        k_any = top + 1
        while k_any < n and hy[k_any] < hy[ad] - S.IMPACT_TOL * torso:
            k_any += 1
        if k >= n and k_any >= n:
            rec.update(reason="clip_end", why=f"clip ends {n - top} frames after the top, hands still up")
            recs.append(rec)
            i = top + 1
            continue
        if k > limit or k >= n:
            down = k_any - top
            rec.update(reason="slow_down", down=down,
                       why=f"downswing {down} frames vs backswing {back} (ratio {down / back:.2f} > {S.DOWN_RATIO})")
            recs.append(rec)
            i = top + 1
            continue
        dx = float(np.abs(hx[k:k + near + 1] - hx[ad]).min()) / torso
        if dx > S.IMPACT_X:
            rec.update(reason="impact_x", why=f"hands {dx:.2f} torso sideways from address (max {S.IMPACT_X})")
            recs.append(rec)
            i = top + 1
            continue
        m = k
        cap = max(frames(3, 1), (k - top) // 2)
        while m + 1 < n and not high(m + 1) and m - k < cap:
            m += 1
        imp = top + int(np.argmax(hy[top:m + 1]))
        rec.update(reason="ok", impact=imp, why=f"down {imp - top} / back {back}")
        recs.append(rec)
        accepted.append((ad, top, imp))
        i = max(imp, j) + 1
    if not recs:
        recs.append({"reason": "no_high",
                     "why": f"hands at most {info['max_hands_above_shoulder']} torso above the shoulder line "
                            f"(top needs > {-S.TOP_BELOW})"})
    # cross-check: the walk above must give the same swings as find_swings
    info["swings"] = len(accepted)
    info["matches_find_swings"] = accepted == [tuple(map(int, s)) for s in S.find_swings(lm, fps)]
    return recs, info


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", type=Path, nargs="+")
    ap.add_argument("--fps", type=float, default=None, help="override the frame rate for every file")
    ap.add_argument("--only-zero", action="store_true", help="only report clips with 0 swings found")
    ap.add_argument("--quiet", action="store_true", help="no per-candidate lines, only one line per clip")
    a = ap.parse_args()
    files: list[Path] = []
    for p in a.paths:
        files += sorted(p.rglob("*.npy")) if p.is_dir() else [p]
    clip_reason = Counter()   # 0-swing clips: the reason of their "best" candidate
    cand_reason = Counter()   # every candidate in every reported clip
    reported = mismatches = 0
    order = ["ok", "impact_x", "slow_down", "clip_end", "address_high", "short_back", "rest", "no_high", "no_pose"]
    for f in files:
        try:
            lm = np.load(f)
        except (ValueError, OSError) as e:
            print(f"{f}: cannot read ({e})")
            continue
        if lm.ndim != 3 or lm.shape[1] < 33:
            print(f"{f}: shape {lm.shape}, expected (frames, 33, 3)")
            continue
        recs, info = diagnose(lm, fps_for(f, a.fps))
        if a.only_zero and info.get("swings", 0) > 0:
            continue
        reported += 1
        mismatches += info.get("matches_find_swings") is False
        for rc in recs:
            cand_reason[rc["reason"]] += 1
        if info.get("swings", 0) == 0:
            # the candidate that got furthest through the rule explains the clip
            best = min(recs, key=lambda rc: order.index(rc["reason"]))
            clip_reason[best["reason"]] += 1
        print(f"{f.name}: {info.get('swings', 0)} swings, {info['frames']} frames @ {info['fps']:g} fps, "
              f"pose {info.get('pose_frac', 0):.0%}, torso {info.get('torso_px', '-')} px, "
              f"hands max {info.get('max_hands_above_shoulder', '-')} torso above shoulders"
              + ("" if info.get("matches_find_swings", True) else "  [!! differs from find_swings]"))
        if not a.quiet:
            for rc in recs:
                where = " ".join(f"{k}={rc[k]}" for k in ("address", "top", "impact") if k in rc)
                print(f"    {rc['reason']:<12} {where:<32} {rc['why']}")
    print(f"\n{reported} clips reported, {mismatches} where this walk differs from find_swings (should be 0)")
    if clip_reason:
        print("0-swing clips by the furthest step reached:")
        for k in order:
            if clip_reason[k]:
                print(f"  {k:<12} {clip_reason[k]}")
    print("all candidate tops by reason:")
    for k in order:
        if cand_reason[k]:
            print(f"  {k:<12} {cand_reason[k]}")


if __name__ == "__main__":
    main()
