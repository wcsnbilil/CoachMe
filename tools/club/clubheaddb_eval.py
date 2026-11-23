"""Score the club tracker (tools/club/club_track.py) against ClubheadDB's hand-labelled clubhead boxes.

Input: the frames kept by clubheaddb_probe.py --keep (one folder of frame_%04d.jpg per clip, frame
counts already checked against the labels). Each clip is turned back into a 30 fps video so that the
tracker's frame index equals the label's frame index, then run_path.py (pose + SwingNet phases) and
club_track.py (address shaft + SAM 2) run on it, and every tracked frame from address to impact is
compared with the label of the same frame.

  python3 tools/club/clubheaddb_eval.py --frames aligned/ --work /tmp/eval --summary summary.md

Distances are in torso lengths (shoulder midpoint to hip midpoint at address, from the pose), so
clips filmed at different sizes are comparable. A frame counts as "within r" when the tracked
clubhead lies within r torso lengths of the label's box centre.
"""
import argparse
import json
import subprocess
import sys
from importlib import resources
from pathlib import Path

import cv2
import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parents[2]
RADII = (0.1, 0.2, 0.4)


def labels():
    with resources.path("clubhead_db.data", "annotations.parquet") as path:
        table = pd.read_parquet(path)
    table["frame"] = table.image_path.str.extract(r"frame_(\d+)\.jpg$")[0].astype(int)
    return table


def to_video(frames: Path, out: Path):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "30", "-i", str(frames / "frame_%04d.jpg"),
                    "-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", str(out)], check=True)


def score(clip, table, phases, npz, size):
    ad, top, imp = phases
    data = np.load(npz)
    heads, torso, start = data["heads"], float(data["torso"]), int(data["start"])
    w, h = size
    rows = []
    for i, head in enumerate(heads):
        frame = start + i
        if frame > imp:
            break
        label = table[table.frame == frame + 1]
        if label.empty or not np.isfinite(label.x_center.iloc[0]):
            continue
        truth = np.array([label.x_center.iloc[0] * w, label.y_center.iloc[0] * h])
        tracked = bool(np.all(np.isfinite(head)))
        error = float(np.linalg.norm(head - truth) / torso) if tracked else np.nan
        rows.append({"clip": clip, "frame": frame, "phase": "backswing" if frame <= top else "downswing",
                     "tracked": tracked, "error": error})
    return rows


def summarise(table, name):
    n = len(table)
    if n == 0:
        return f"| {name} | 0 | - | - | - | - | - |"
    tracked = table[table.tracked]
    within = [f"{(tracked.error <= r).sum() / n:.0%}" for r in RADII]
    median = f"{tracked.error.median():.3f}" if len(tracked) else "-"
    return f"| {name} | {n} | {len(tracked) / n:.0%} | {median} | " + " | ".join(within) + " |"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--summary")
    ap.add_argument("--sam", default="sam2_t.pt")
    a = ap.parse_args()
    frames_root, work = Path(a.frames), Path(a.work)
    videos, report, club = work / "videos", work / "report", work / "club"
    videos.mkdir(parents=True, exist_ok=True)
    clips = sorted(p.name for p in frames_root.iterdir() if p.is_dir())
    sizes = {}
    for clip in clips:
        to_video(frames_root / clip, videos / f"{clip}.mp4")
        first = cv2.imread(str(frames_root / clip / "frame_0001.jpg"))
        sizes[clip] = (first.shape[1], first.shape[0])
    subprocess.run([sys.executable, str(ROOT / "tools/faults/run_path.py"), "--no-sheet", "--out", str(report)]
                   + sum((["--video", str(videos / f"{c}.mp4")] for c in clips), []), check=True)
    subprocess.run([sys.executable, str(ROOT / "tools/club/club_track.py"), str(report), "--videos-dir", str(videos),
                    "--out", str(club), "--model", a.sam], check=True)
    results = {r["name"]: r for r in json.loads((report / "results.json").read_text(encoding="utf-8"))}
    tracks = {r["name"]: r for r in json.loads((club / "results.json").read_text(encoding="utf-8"))}
    table = labels()
    rows, notes = [], []
    for clip in clips:
        r, t = results.get(clip, {}), tracks.get(clip, {})
        npz = club / f"{clip}.npz"
        if not r.get("phases") or not npz.exists():
            notes.append(f"- {clip}：没有结果（阶段：{r.get('phases')}，跟踪：{t.get('status', '无 npz')}）")
            continue
        rows += score(clip, table[table.video_id == clip], r["phases"], npz, sizes[clip])
    scored = pd.DataFrame(rows, columns=["clip", "frame", "phase", "tracked", "error"])
    head = "| 范围 | 标注帧 | 跟踪到 | 误差中位数（躯干长） | " + " | ".join(f"≤{r} 躯干长" for r in RADII) + " |"
    lines = ["### 现有杆头原型（直线检测 + SAM 2）对 ClubheadDB 人工标注", "",
             f"{len(clips)} 段；只计准备到击球之间、有杆头标注的帧。", "", head, "|---|---|---|---|" + "---|" * len(RADII),
             summarise(scored, "全部"), summarise(scored[scored.phase == "backswing"], "上杆（准备→顶点）"),
             summarise(scored[scored.phase == "downswing"], "下杆（顶点→击球）")]
    lines += [summarise(scored[scored.clip == c], c) for c in clips]
    if notes:
        lines += ["", "没有结果的段：", ""] + notes
    text = "\n".join(lines) + "\n"
    print(text)
    if a.summary:
        Path(a.summary).write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
