"""Pose (hd_pipeline.pose_video) + single-swing split with tools\\split\\swing_split.find_swings at the clip's real fps.
Replaces hd_pipeline.segment(), whose frame-count thresholds are tuned for 30 fps real-time video.
Output is compatible with hd_pipeline: <out>/results.json rows (name, video, lm, phases, fps, + path_fault fields),
<out>/landmarks/<id>.npy and <id>.fps.json. Resumable: cached landmarks are reused.

2026-11-12 (as hd_pipeline.py at claude/camera-res a12272f):
- analyze() gets lead-in frames before the split's address (at least 30, about 1 s, stretched for slow motion, never
  into the previous swing), because that address is often already in the takeaway and the camera check then reads the
  shoulder line as too wide. Phases passed to analyze are relative to the lead start; rows carry lead_start, and
  address_used is back in frames of the whole video.
- --code picks the checkout whose tools\\split, tools\\faults and tools\\club are used (default: the main repo).
- --landmarks reuses keypoints cached by an earlier run (no MediaPipe), e.g. hd_swings\\seg_p0\\landmarks.
usage: python hd_split.py <video dir or list.txt> --out DIR [--limit N] [--code CHECKOUT] [--landmarks DIR]"""
import argparse, json, os, sys
from pathlib import Path
import cv2, numpy as np

ROOT = Path(r"C:\Users\k8881\coachme-bench\coachme")
LEAD_S = 1.0          # seconds of lead-in before the split's address
SLOW_SWING_S = 2.0    # a longer address->impact is slow motion: lead-in stretched by duration / 1 s


def lead_frames(ad, imp, fps):
    took = (imp - ad) / fps
    slow = took if took > SLOW_SWING_S else 1.0
    return max(30, int(round(LEAD_S * fps * slow)))


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=Path); ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--code", type=Path, default=ROOT, help="checkout providing tools/split, tools/faults, tools/club")
    ap.add_argument("--landmarks", type=Path, help="reuse <id>.npy + <id>.fps.json from this folder instead of running pose")
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    a = ap.parse_args()
    for d in ("tools/club", "tools/split", "tools/faults"):
        sys.path.insert(0, str(a.code / d))
    from swing_split import find_swings, windows
    from path_fault import analyze
    exts = (".mp4", ".webm", ".mkv", ".mov")
    vids = sorted(p for p in a.src.iterdir() if p.suffix.lower() in exts) if a.src.is_dir() else \
        [Path(p) for p in a.src.read_text(encoding="utf-8-sig").splitlines() if p.strip()]
    if a.limit: vids = vids[:a.limit]
    lmdir = a.landmarks or (a.out / "landmarks")
    lmdir.mkdir(parents=True, exist_ok=True); a.out.mkdir(parents=True, exist_ok=True)
    rows, per_video = [], []
    for n, v in enumerate(vids, 1):
        npy = lmdir / f"{v.stem}.npy"; fj = npy.with_suffix(".fps.json")
        if npy.exists() and fj.exists():
            lm = np.load(npy); fps = json.loads(fj.read_text())["fps"]
        elif a.landmarks:
            print(f"{n}/{len(vids)} {v.stem}: no cached keypoints, skipped", flush=True); continue
        else:
            if not v.exists():
                print(f"{n}/{len(vids)} {v.stem}: missing", flush=True); continue
            from hd_pipeline import pose_video
            try:
                lm, fps = pose_video(v, a.model)
            except Exception as e:  # one unreadable file must not stop the batch
                print(f"{n}/{len(vids)} {v.stem}: pose failed {e!r}", flush=True); continue
            if len(lm) == 0:
                print(f"{n}/{len(vids)} {v.stem}: no frames", flush=True); continue
            tmp = npy.with_suffix(".tmp.npy"); np.save(tmp, lm.astype(np.float32)); os.replace(tmp, npy)
            fj.write_text(json.dumps({"fps": float(fps), "frames": len(lm)}))
        if lm.ndim != 3 or len(lm) == 0: continue
        segs = find_swings(lm.astype(float), fps)
        for s, (ad, top, imp) in enumerate(segs):
            lo = max(ad - lead_frames(ad, imp, fps), segs[s - 1][2] + 1 if s else 0, 0)
            try:
                r = analyze(lm[lo:imp + 1].astype(float).copy(), ad - lo, top - lo, imp - lo)
                r = {k: val for k, val in r.items() if k != "hands"}
                if "address_used" in r:
                    r["address_used"] = int(r["address_used"]) + lo  # back to frames of the whole video
            except Exception as e:
                r = {"verdict": f"analyze failed {e!r}"}
            r.update(name=f"{v.stem}_s{s}", video=str(v.resolve()), lm=str(npy.resolve()), phases=[int(ad), int(top), int(imp)],
                     fps=float(fps), lead_start=int(lo))
            rows.append(r)
        per_video.append({"video": v.stem, "frames": int(len(lm)), "fps": float(fps), "swings": len(segs),
                          "detected": round(float(np.isfinite(lm[:, 0, 0]).mean()), 3),
                          "windows": windows(segs, len(lm), fps)})
        print(f"{n}/{len(vids)} {v.stem}: {len(lm)} frames @ {fps:.2f} fps, {len(segs)} swings", flush=True)
        for name, obj in (("results", rows), ("videos", per_video)):
            tmp = a.out / f"{name}.tmp.json"
            tmp.write_text(json.dumps(obj, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
            os.replace(tmp, a.out / f"{name}.json")
    print(len(rows), "swings from", len(per_video), "videos ->", a.out / "results.json")


if __name__ == "__main__":
    main()
