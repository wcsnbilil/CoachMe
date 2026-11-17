"""Pose + swing segmentation for long web clips (several swings, replays, split screens).

SwingNet expects one swing per clip, so here each swing is cut out from the hands' height alone:
top = hands clearly above the shoulders at a local maximum of height; address = the last still
moment with the hands low before it; impact = first frame after top where the hands are back at
the address height. Each swing is then checked with path_fault.analyze (camera / side / hand path).

usage: python tools/club/hd_pipeline.py <video dir or list.txt> --out hd_report
Output: hd_report/results.json (rows like run_path.py plus "video" and "lm" paths),
        hd_report/landmarks/<video id>.npy (whole clip, pixel coords).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
from path_fault import analyze  # noqa: E402

LW, RW, LS, RS, LH, RH = 15, 16, 11, 12, 23, 24


def pose_video(path: Path, model: Path, max_h: int = 540) -> tuple[np.ndarray, float]:
    import mediapipe as mp
    from mediapipe.tasks import python as mpp
    from mediapipe.tasks.python import vision
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)  # iPhone portrait clips carry rotation metadata; OpenCV ignores it by default
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    opts = vision.PoseLandmarkerOptions(base_options=mpp.BaseOptions(model_asset_path=str(model)),
                                        running_mode=vision.RunningMode.VIDEO, num_poses=1)
    rows = []
    with vision.PoseLandmarker.create_from_options(opts) as lm:
        i = 0
        while True:
            ok, img = cap.read()
            if not ok:
                break
            h, w = img.shape[:2]
            s = min(1.0, max_h / h)
            small = cv2.resize(img, (int(w * s), int(h * s))) if s < 1 else img
            res = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB,
                                               data=cv2.cvtColor(small, cv2.COLOR_BGR2RGB)), int(i * 1000 / fps))
            if res.pose_landmarks:
                rows.append([(p.x * w, p.y * h, p.visibility) for p in res.pose_landmarks[0]])
            else:
                rows.append(np.full((33, 3), np.nan))
            i += 1
    cap.release()
    return np.asarray(rows, float), fps


def smooth(v: np.ndarray, k: int) -> np.ndarray:
    v = v.copy()
    ok = np.isfinite(v)
    if ok.sum() < 2:
        return v
    v[~ok] = np.interp(np.flatnonzero(~ok), np.flatnonzero(ok), v[ok])
    k = max(1, k | 1)
    pad = np.pad(v, k // 2, mode="edge")
    return np.convolve(pad, np.ones(k) / k, mode="valid")


def segment(lm: np.ndarray) -> list[tuple[int, int, int]]:
    x = lm.copy()
    x[~(x[:, :, 2] >= 0.5), :2] = np.nan
    hands = np.nanmean(x[:, [LW, RW], :2], 1)
    sh = np.nanmean(x[:, [LS, RS], :2], 1)
    hip = np.nanmean(x[:, [LH, RH], :2], 1)
    torso = np.nanmedian(np.linalg.norm(sh - hip, axis=1))
    if not np.isfinite(torso) or torso < 10:
        return []
    n = len(x)
    hy = smooth(hands[:, 1], 3)
    hx = smooth(hands[:, 0], 3)
    shy = smooth(sh[:, 1], 9)
    hipy = smooth(hip[:, 1], 9)
    speed = np.r_[0, np.hypot(np.diff(hx), np.diff(hy))] / torso
    out = []
    i = 1
    prev_end = 0
    while i < n - 1:
        # candidate top: hands above shoulders, local minimum of y over a window
        if hy[i] < shy[i] - 0.15 * torso and hy[i] <= hy[max(0, i - 5):i + 6].min():
            j = i
            while j < n and hy[j] < shy[j] - 0.15 * torso:
                j += 1
            top = i + int(np.argmin(hy[i:j]))  # highest hands within this excursion
            # address: the hands' lowest point before the top (since the previous swing), then the
            # last frame still at that height = moment before takeaway. (Walking back until "still"
            # stopped inside slow-motion takeaways.)
            lo = max(prev_end, top - 900)
            if top - lo < 6:
                i = top + 1
                continue
            jlow = lo + int(np.argmax(hy[lo:top]))
            level = hy[jlow]
            ad = max(j for j in range(jlow, top) if hy[j] >= level - 0.05 * torso)
            back = top - ad
            if back < 4 or not (hy[ad] > hipy[ad] - 0.1 * torso):
                i = top + 1
                continue
            # impact: after top, hands come back down to the address height near the address x
            k = top + 1
            while k < n and not (hy[k] >= hy[ad] - 0.25 * torso):
                k += 1
                if k - top > 3 * (top - ad) + 10:
                    break
            if k >= n or hy[k] < hy[ad] - 0.25 * torso or abs(hx[k] - hx[ad]) > 0.6 * torso:
                i = top + 1
                continue
            down, back = k - top, top - ad
            if down < 2 or down > back * 1.5:  # downswing is faster than backswing
                i = top + 1
                continue
            # impact = hands' lowest point before they rise again for the finish (the first return to
            # address height comes too early in slow motion: hands get low before the club does)
            m = k
            while m + 1 < n and hy[m + 1] >= shy[m + 1] - 0.15 * torso and m - k < max(3, down // 2):
                m += 1
            k = top + int(np.argmax(hy[top:m + 1]))
            out.append((ad, top, k))
            prev_end = k
            i = max(k, j) + 1
        else:
            i += 1
    return out


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", type=Path)
    ap.add_argument("--out", type=Path, default=Path("hd_report"))
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    a = ap.parse_args()
    vids = sorted(a.src.glob("*.mp4")) if a.src.is_dir() else [Path(p) for p in a.src.read_text(encoding="utf-8-sig").split()]
    (a.out / "landmarks").mkdir(parents=True, exist_ok=True)
    rows = []
    for n, v in enumerate(vids, 1):
        npy = a.out / "landmarks" / f"{v.stem}.npy"
        if npy.exists():
            lm = np.load(npy)
        else:
            lm, _ = pose_video(v, a.model)
            if len(lm) == 0:
                print(f"{n}/{len(vids)} {v.stem}: 读不到视频帧", flush=True)
                continue
            tmp = npy.with_suffix(".tmp.npy")
            np.save(tmp, lm)
            os.replace(tmp, npy)  # atomic: a killed run never leaves a half-written cache
        if lm.ndim != 3 or len(lm) == 0:
            print(f"{n}/{len(vids)} {v.stem}: 读不到视频帧", flush=True)
            continue
        segs = segment(lm)
        for s, (ad, top, imp) in enumerate(segs):
            r = analyze(lm[ad:imp + 1].copy(), 0, top - ad, imp - ad)
            r = {k: val for k, val in r.items() if k != "hands"}
            r.update(name=f"{v.stem}_s{s}", video=str(v.resolve()), lm=str(npy.resolve()), phases=[ad, top, imp])
            rows.append(r)
        print(f"{n}/{len(vids)} {v.stem}: {len(lm)} frames, {len(segs)} swings,",
              [r["verdict"] for r in rows if r["name"].startswith(v.stem + "_s")], flush=True)
        tmp = a.out / "results.tmp.json"
        tmp.write_text(json.dumps(rows, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
        os.replace(tmp, a.out / "results.json")
    print(len(rows), "swings ->", a.out / "results.json")


if __name__ == "__main__":
    main()
