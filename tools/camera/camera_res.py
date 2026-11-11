"""Is the camera check (shoulder / hip line width at address) calibrated for phone resolution?

MAX_LINE_WIDTH = 0.2 was set on GolfDB clips that are 160 px on the long side. On computer B, 628 of
807 HD down-the-line swings were refused as "camera off the target line" with shoulder widths of
0.20-0.43, while the overlays looked like normal down-the-line shots. This runs the same swing cut
(same frames, same phases, fresh tracker, same lead-in as hd_reencode.py) with MediaPipe fed at
different sizes and prints the camera numbers for each, so a resolution effect shows up directly.

  python tools/camera/camera_res.py <hd report dir or results.json> [...] [--limit 60]
         [--heights long160 270 540 full] [--only-reason 机位] [--out camera_res.json]

long160 = the long side shrunk to 160 px like GolfDB's videos_160; a number = model input height;
full = the source frames.

For every input size the widths are also measured at several address frames (the second suspect: a
late address, when the body has started to turn, widens the shoulder line):
  given   the address in the report (the splitter's / pipeline's)
  used    what analyze() uses: `given` walked back to the last still hands frame (still_address)
  still   the frame where hands and both shoulders are still before the takeaway (PR #12's rule)
  swingnet SwingNet's address on the cut (with --swingnet; needs the SwingNet weights, like run_path)
Prints numbers and verdicts only; no frames are written. Temp data stays
in memory.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
sys.path.insert(0, str(ROOT / "tools" / "robustness"))
import warnings  # noqa: E402

from path_fault import (L_HIP, L_SH, MAX_LINE_WIDTH, R_HIP, R_SH, _odd, _smooth, analyze, body_at,  # noqa: E402
                        camera_check, hand_track)
from hd_reencode import pose, read_cut, write_lossless  # noqa: E402

ADDRESS_STILL = 0.03  # PR #12 (claude/address-still), copied: not in the app's rules


def hands_still_address(tracks, address: int, top: int, torso: float):
    """PR #12's still-body address (copied as it was): walking back from the top, the first frame where
    hands and both shoulders stayed within ADDRESS_STILL torso over [f - s, f], s = max(3, (top - f) // 3)."""
    lo = max(0, address - (top - address))
    hy = tracks[0][:, 1]
    if not (np.isfinite(hy[address]) and np.isfinite(hy[top])):
        return None
    half = hy[top] + 0.5 * (hy[address] - hy[top])
    below = [f for f in range(lo, top) if np.isfinite(hy[f]) and hy[f] >= half]
    if not below:
        return None
    moved = False
    for f in range(below[-1], lo - 1, -1):
        s = min(max(3, (top - f) // 3), f - lo)
        if s < 2:
            break
        still, seen = True, False
        for t in tracks:
            if not np.isfinite(t[f]).all():
                continue
            d = np.hypot(*(t[f - s:f + 1] - t[f]).T)
            d = d[np.isfinite(d)]
            seen = True
            if len(d) and d.max() > ADDRESS_STILL * torso:
                still = False
                break
        if not still:
            moved = True
        elif seen and moved:
            return f
    return None


def widths_at(landmarks: np.ndarray, frames: dict, address: int, top: int, impact: int) -> dict:
    """Camera widths (as analyze measures them) at each named address frame."""
    lm = landmarks.astype(float).copy()
    lm[~(lm[:, :, 2] >= 0.5), 0:2] = np.nan
    k = _odd((impact - address) / 20)
    h = max(2, k // 2)
    out = {}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        for name, f in frames.items():
            if f is None or not (0 <= f < top):
                out[name] = None
                continue
            body = body_at(lm, f, 0, top - 1, h)
            sh = np.nanmean(body[[L_SH, R_SH]], axis=0)
            hip = np.nanmean(body[[L_HIP, R_HIP]], axis=0)
            torso = float(np.linalg.norm(sh - hip))
            if not np.isfinite(torso) or torso < 1:
                out[name] = None
                continue
            c = camera_check(body, torso)
            out[name] = {"frame": int(f), "shoulder": c["shoulder_width"], "hip": c["hip_width"],
                         "widest": max(c["shoulder_width"], c["hip_width"])}
    return out


def still_frame(landmarks: np.ndarray, address: int, top: int, impact: int):
    lm = landmarks.astype(float).copy()
    lm[~(lm[:, :, 2] >= 0.5), 0:2] = np.nan
    k = _odd((impact - address) / 20)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        sh = np.nanmean(lm[address, [L_SH, R_SH], :2], axis=0)
        hip = np.nanmean(lm[address, [L_HIP, R_HIP], :2], axis=0)
        torso = float(np.linalg.norm(sh - hip))
        if not np.isfinite(torso) or torso < 1:
            return None
        hands = _smooth(hand_track(lm, torso), k)
        tracks = [hands] + [_smooth(lm[:, j, 0:2], k) for j in (L_SH, R_SH)]
        return hands_still_address(tracks, address, top, torso)


def swingnet_address(frames: list, fps: float):
    import tempfile
    sys.path.insert(0, str(ROOT / "tools" / "benchmark"))
    from run_path import swingnet_phases
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "cut.mkv"
        write_lossless(frames, fps, p)
        ph = swingnet_phases(p, "numpy")
    return ph[0] if ph else None


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", type=Path, nargs="+")
    ap.add_argument("--heights", nargs="+", default=["long160", "270", "540", "full"])
    ap.add_argument("--limit", type=int, default=60)
    ap.add_argument("--only-reason", default="", help="only swings whose report reason contains this (e.g. 机位)")
    ap.add_argument("--lead", type=int, default=30)
    ap.add_argument("--max-frames", type=int, default=400, help="skip swings longer than this from lead to impact")
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    ap.add_argument("--swingnet", action="store_true", help="also measure at SwingNet's address on the cut")
    ap.add_argument("--out", type=Path, default=Path("camera_res.json"))
    a = ap.parse_args()
    rows = []
    for rep in a.reports:
        f = rep / "results.json" if rep.is_dir() else rep
        if f.exists():
            rows += json.loads(f.read_text(encoding="utf-8"))
    if a.only_reason:
        rows = [r for r in rows if a.only_reason in (r.get("reason") or "")]
    rows = [r for r in rows if r.get("phases") and r.get("video")][:a.limit]
    out = []
    for n, r in enumerate(rows, 1):
        ad, top, imp = r["phases"]
        lo = max(0, ad - a.lead)
        if imp - lo + 1 > a.max_frames:
            print(f"{n}/{len(rows)} {r['name']}: {imp - lo + 1} frames, skipped", flush=True)
            continue
        frames, fps = read_cut(r["video"], lo, imp)
        if len(frames) < imp - lo + 1:
            print(f"{n}/{len(rows)} {r['name']}: cut too short, skipped", flush=True)
            continue
        h, w = frames[0].shape[:2]
        rec = {"name": r["name"], "source": [w, h], "report_reason": r.get("reason"), "by_height": {}}
        parts = []
        sn = swingnet_address(frames, fps) if a.swingnet else None
        for v in a.heights:
            mh = h if v == "full" else int(round(h * 160 / max(h, w))) if v == "long160" else int(v)
            lms = pose(frames, fps, a.model, mh)
            res = analyze(lms, ad - lo, top - lo, imp - lo)
            cam = res.get("camera") or {}
            at = widths_at(lms, {"given": ad - lo, "used": res.get("address_used"),
                                 "still": still_frame(lms, ad - lo, top - lo, imp - lo),
                                 "swingnet": sn}, ad - lo, top - lo, imp - lo)
            rec["by_height"][v] = {"model_height": mh, "verdict": res["verdict"], "reason": res.get("reason"),
                                   "offset": res.get("offset"), "confidence": res.get("confidence"),
                                   "shoulder_width": cam.get("shoulder_width"), "hip_width": cam.get("hip_width"),
                                   "address_used": res.get("address_used"), "at": at}
            ats = " ".join(f"{kk}@{x['frame']}={x['widest']}" for kk, x in at.items() if x)
            parts.append(f"{v}: {res['verdict']}{'（' + res['reason'] + '）' if res.get('reason') else ''} [{ats}]")
        out.append(rec)
        print(f"{n}/{len(rows)} {r['name']} ({w}x{h}): " + " | ".join(parts), flush=True)
        a.out.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")

    names = ["given", "used", "still", "swingnet"]
    print(f"\n### 宽度（肩、髋较宽者，躯干长度）：输入尺寸 × 准备帧。每格：中位 / 超过 {MAX_LINE_WIDTH * 1.05:.3f}（拒判线）的比例")
    print("| 输入 | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    for v in a.heights:
        cells = []
        for nm in names:
            ws = [o["by_height"][v]["at"][nm]["widest"] for o in out
                  if v in o["by_height"] and o["by_height"][v]["at"].get(nm)]
            cells.append(f"{np.median(ws):.3f} / {sum(x > MAX_LINE_WIDTH * 1.05 for x in ws)}/{len(ws)}" if ws else "—")
        print(f"| {v} | " + " | ".join(cells) + " |")
    print(f"\n{len(out)} swings. Camera limit {MAX_LINE_WIDTH} (refused above {MAX_LINE_WIDTH * 1.05:.3f}).")
    print("| input | median shoulder | median hip | wider of the two > limit | refused (any reason) | judged |")
    print("|---|---|---|---|---|---|")
    for v in a.heights:
        bh = [o["by_height"][v] for o in out if v in o["by_height"]]
        sh = [b["shoulder_width"] for b in bh if isinstance(b["shoulder_width"], (int, float))]
        hp = [b["hip_width"] for b in bh if isinstance(b["hip_width"], (int, float))]
        wide = sum(1 for b in bh if max([x for x in (b["shoulder_width"], b["hip_width"]) if isinstance(x, (int, float))],
                                         default=0) > MAX_LINE_WIDTH * 1.05)
        ref = sum(b["verdict"] == "无法判断" for b in bh)
        print(f"| {v} | {np.median(sh) if sh else float('nan'):.3f} | {np.median(hp) if hp else float('nan'):.3f} | "
              f"{wide}/{len(bh)} | {ref}/{len(bh)} | {len(bh) - ref}/{len(bh)} |")


if __name__ == "__main__":
    main()
