"""Re-encode at real phone bitrates on HD clips: does the path verdict survive?

The GolfDB re-encode test (run_path.py --perturb reencode) works on 160x160 clips, where a CRF 28
pass is much harsher than anything a phone does to a 1080p video. This takes hd_pipeline.py
reports (HD video + address/top/impact per swing), cuts each swing out of its source video,
and for each bitrate encodes it again as 1080p H.264 (or the source height when smaller), then
runs MediaPipe and path_fault.analyze on the original cut and on every re-encoded copy, the same
way for all of them (same lead-in frames, same pose input height as hd_pipeline.py).

Writes one results file per variant in run_path.py's format, so flip_report.py reads them:
  <out>/none.json, <out>/h264_16M.json, <out>/h264_8M.json, ...
  python tools/robustness/flip_report.py <out>/none.json <out>/h264_*.json --title "高清片段，手机码率重新编码"

Only numbers and verdicts are written; the cut and re-encoded videos stay in a temp folder that
is deleted swing by swing. Never commit or upload the clips or the output videos.

usage: python tools/robustness/hd_reencode.py <hd report dir> [...] --out hd_reencode
       [--bitrates 16M 8M 4M] [--height 1080]
"""
from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
from path_fault import analyze  # noqa: E402

# iPhone records 1080p30 H.264 at about 16 Mbit/s; "most compatible" exports and
# messaging apps re-share at roughly 8 and 2-4 Mbit/s.
DEFAULT_BITRATES = ("16M", "8M", "4M")


def read_cut(video: str, lo: int, hi: int) -> tuple[list, float]:
    cap = cv2.VideoCapture(video)
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    cap.set(cv2.CAP_PROP_POS_FRAMES, lo)
    frames = []
    for _ in range(lo, hi + 1):
        ok, img = cap.read()
        if not ok:
            break
        frames.append(img)
    cap.release()
    return frames, fps


def write_lossless(frames: list, fps: float, path: Path) -> None:
    """The cut as a near-lossless intermediate (FFV1), so the re-encode starts from the source pixels."""
    h, w = frames[0].shape[:2]
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "bgr24", "-s", f"{w}x{h}",
                          "-r", f"{fps:.6f}", "-i", "-", "-c:v", "ffv1", str(path)], stdin=subprocess.PIPE)
    for f in frames:
        p.stdin.write(np.ascontiguousarray(f).tobytes())
    p.stdin.close()
    if p.wait():
        raise RuntimeError("ffmpeg (ffv1) failed")


def reencode(src: Path, dst: Path, bitrate: str, height: int) -> None:
    rate = int(bitrate.rstrip("M")) * 1000
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(src), "-an",
                    "-vf", f"scale=-2:'min({height},ih)'", "-c:v", "libx264", "-preset", "medium",
                    "-b:v", f"{rate}k", "-maxrate", f"{rate * 3 // 2}k", "-bufsize", f"{rate * 2}k",
                    "-pix_fmt", "yuv420p", "-threads", "1", str(dst)], check=True)


def pose(frames: list, fps: float, model: Path, max_h: int) -> np.ndarray:
    """Same as hd_pipeline.pose_video: shrink to max_h for the model, landmarks back in source pixels."""
    import mediapipe as mp
    from mediapipe.tasks import python as mpp
    from mediapipe.tasks.python import vision
    opts = vision.PoseLandmarkerOptions(base_options=mpp.BaseOptions(model_asset_path=str(model)),
                                        running_mode=vision.RunningMode.VIDEO, num_poses=1)
    out = np.full((len(frames), 33, 3), np.nan)
    with vision.PoseLandmarker.create_from_options(opts) as lm:
        for i, img in enumerate(frames):
            h, w = img.shape[:2]
            s = min(1.0, max_h / h)
            small = cv2.resize(img, (int(w * s), int(h * s)), interpolation=cv2.INTER_AREA) if s < 1 else img
            res = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB,
                                               data=cv2.cvtColor(small, cv2.COLOR_BGR2RGB)), int(i * 1000 / fps))
            if res.pose_landmarks:
                out[i] = [(p.x * w, p.y * h, p.visibility) for p in res.pose_landmarks[0]]
    return out


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", type=Path, nargs="+")
    ap.add_argument("--out", type=Path, default=Path("hd_reencode"))
    ap.add_argument("--bitrates", nargs="+", default=list(DEFAULT_BITRATES))
    ap.add_argument("--height", type=int, default=1080, help="re-encode height (the source height when smaller)")
    ap.add_argument("--pose-height", type=int, default=540, help="model input height, as in hd_pipeline.py")
    ap.add_argument("--lead", type=int, default=30, help="frames before address fed to the tracker first")
    ap.add_argument("--judged-only", action="store_true", help="only swings hd_pipeline judged (the ~38 of the 160px check)")
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    rows = []
    for rep in a.reports:
        f = rep / "results.json" if rep.is_dir() else rep
        if f.exists():
            rows += json.loads(f.read_text(encoding="utf-8"))
    if a.judged_only:
        rows = [r for r in rows if r.get("verdict") != "无法判断"]
    variants = ["none"] + [f"h264_{b}" for b in a.bitrates]
    results = {v: [] for v in variants}
    tmp = Path(tempfile.mkdtemp(prefix="hd_reencode_"))
    try:
        for n, r in enumerate(rows, 1):
            ad, top, imp = r["phases"]
            lo = max(0, ad - a.lead)
            frames, fps = read_cut(r["video"], lo, imp)
            if len(frames) < imp - lo + 1:
                print(f"{n}/{len(rows)} {r['name']}: cut too short, skipped", flush=True)
                continue
            src_h = frames[0].shape[0]
            cut = tmp / "cut.mkv"
            write_lossless(frames, fps, cut)
            line = []
            for v in variants:
                if v == "none":
                    fr = frames
                else:
                    enc = tmp / f"{v}.mp4"
                    reencode(cut, enc, v.split("_")[1], a.height)
                    fr, _ = read_cut(str(enc), 0, len(frames) - 1)
                    enc.unlink()
                    if len(fr) != len(frames):
                        print(f"  {v}: {len(fr)} frames back, expected {len(frames)}", flush=True)
                res = analyze(pose(fr, fps, a.model, a.pose_height), ad - lo, top - lo, imp - lo)
                res = {k: x for k, x in res.items() if k != "hands"}
                res.update(name=r["name"], perturb=v, source_height=src_h, phases=[ad, top, imp])
                results[v].append(res)
                line.append(f"{v} {res['verdict']} {res.get('offset', '')}{res.get('reason', '')}")
            cut.unlink()
            print(f"{n}/{len(rows)} {r['name']} ({src_h}p): " + " | ".join(line), flush=True)
            for v in variants:  # rewrite after every swing so a stopped run keeps what it has
                (a.out / f"{v}.json").write_text(json.dumps(results[v], ensure_ascii=False, indent=1, default=float),
                                                 encoding="utf-8")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("next: python tools/robustness/flip_report.py", a.out / "none.json",
          " ".join(str(a.out / f"{v}.json") for v in variants[1:]))


if __name__ == "__main__":
    main()
