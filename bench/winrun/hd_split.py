"""Pose (hd_pipeline.pose_video) + single-swing split with tools\\split\\swing_split.find_swings at the clip's real fps.
Replaces hd_pipeline.segment(), whose frame-count thresholds are tuned for 30 fps real-time video.
Output is compatible with hd_pipeline: <out>/results.json rows (name, video, lm, phases, fps, + path_fault fields),
<out>/landmarks/<id>.npy and <id>.fps.json. Resumable: cached landmarks are reused.
usage: python hd_split.py <video dir or list.txt> --out DIR [--limit N]"""
import argparse, json, os, sys
from pathlib import Path
import cv2, numpy as np

ROOT = Path(r"C:\Users\k8881\coachme-bench\coachme")
for d in ("tools/club", "tools/split", "tools/faults"):
    sys.path.insert(0, str(ROOT / d))
from hd_pipeline import pose_video  # noqa: E402
from swing_split import find_swings, windows  # noqa: E402
from path_fault import analyze  # noqa: E402


def video_fps(path):
    cap = cv2.VideoCapture(str(path)); fps = cap.get(cv2.CAP_PROP_FPS) or 30.0; cap.release()
    return float(fps)


def main():
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=Path); ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    a = ap.parse_args()
    exts = (".mp4", ".webm", ".mkv", ".mov")
    vids = sorted(p for p in a.src.iterdir() if p.suffix.lower() in exts) if a.src.is_dir() else \
        [Path(p) for p in a.src.read_text(encoding="utf-8-sig").splitlines() if p.strip()]
    if a.limit: vids = vids[:a.limit]
    (a.out / "landmarks").mkdir(parents=True, exist_ok=True)
    rows, per_video = [], []
    for n, v in enumerate(vids, 1):
        npy = a.out / "landmarks" / f"{v.stem}.npy"; fj = npy.with_suffix(".fps.json")
        if npy.exists() and fj.exists():
            lm = np.load(npy); fps = json.loads(fj.read_text())["fps"]
        else:
            if not v.exists():
                print(f"{n}/{len(vids)} {v.stem}: missing", flush=True); continue
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
            try:
                r = analyze(lm[ad:imp + 1].astype(float).copy(), 0, top - ad, imp - ad)
                r = {k: val for k, val in r.items() if k != "hands"}
            except Exception as e:
                r = {"verdict": f"analyze failed {e!r}"}
            r.update(name=f"{v.stem}_s{s}", video=str(v.resolve()), lm=str(npy.resolve()), phases=[int(ad), int(top), int(imp)], fps=float(fps))
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
