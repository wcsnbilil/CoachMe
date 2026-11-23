"""Train a small clubhead detector on some ClubheadDB golfers and score it on the held-out ones.

Research only: ClubheadDB is CC BY-NC 4.0 and Ultralytics is AGPL-3.0, so neither the data nor the
weights go into the app or the repository. The question is how well a detector trained on a few
hundred labelled frames finds the clubhead on golfers it has never seen, especially in the fast,
blurred part of the swing.

  python3 tools/club/clubheaddb_train.py --frames aligned/ --holdout swing_035,swing_037 --work /tmp/fold --summary fold.md

Frames are binned by how far the labelled clubhead moved since the previous frame (fraction of the
frame height): still < 0.005, moving < 0.03, fast >= 0.03. A detection is "within r" when its box
centre lies within r frame heights of the label's centre. Frames labelled as clubhead not visible
count separately: any detection there is a false positive.
"""
import argparse
import os
import shutil
from importlib import resources
from pathlib import Path

import numpy as np
import pandas as pd

RADII = (0.02, 0.05)
BINS = (("静止", 0.0, 0.005), ("移动", 0.005, 0.03), ("快速", 0.03, np.inf))


def labels(clips):
    with resources.path("clubhead_db.data", "annotations.parquet") as path:
        table = pd.read_parquet(path)
    table = table[table["video_id"].isin(clips)].copy()
    table["frame"] = table["image_path"].str.extract(r"frame_(\d+)\.jpg$")[0].astype(int)
    return table.sort_values(["video_id", "frame"])


def build(frames_root, table, clips, split_dir):
    images, labs = split_dir / "images", split_dir / "labels"
    images.mkdir(parents=True, exist_ok=True)
    labs.mkdir(parents=True, exist_ok=True)
    for row in table[table["video_id"].isin(clips)].itertuples():
        name = f"{row.video_id}_{row.frame:04d}"
        src = frames_root / row.video_id / f"frame_{row.frame:04d}.jpg"
        if not src.exists():
            continue
        os.symlink(src.resolve(), images / f"{name}.jpg")
        text = "" if np.isnan(row.x_center) else f"0 {row.x_center} {row.y_center} {row.width} {row.height}\n"
        (labs / f"{name}.txt").write_text(text)


def motion(table):
    out = []
    for _, clip in table.groupby("video_id"):
        xy = clip[["x_center", "y_center"]].to_numpy()
        step = np.full(len(clip), np.nan)
        step[1:] = np.linalg.norm(xy[1:] - xy[:-1], axis=1)
        out.append(pd.Series(step, index=clip.index))
    return pd.concat(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", required=True)
    ap.add_argument("--holdout", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--summary")
    ap.add_argument("--model", default="yolo11n.pt")
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--hours", type=float, default=2.5)
    a = ap.parse_args()
    from ultralytics import YOLO

    frames_root, work = Path(a.frames), Path(a.work)
    shutil.rmtree(work, ignore_errors=True)
    clips = sorted(p.name for p in frames_root.iterdir() if p.is_dir())
    test = [c for c in a.holdout.split(",") if c]
    train = [c for c in clips if c not in test]
    table = labels(clips)
    build(frames_root, table, train, work / "ds" / "train")
    build(frames_root, table, test, work / "ds" / "test")
    (work / "data.yaml").write_text(f"path: {work / 'ds'}\ntrain: train/images\nval: train/images\nnames:\n  0: clubhead\n")

    model = YOLO(a.model)
    model.train(data=str(work / "data.yaml"), epochs=a.epochs, time=a.hours, imgsz=a.imgsz, batch=16, device="cpu",
                workers=2, val=False, plots=False, project=str(work / "runs"), name="fold", exist_ok=True, verbose=False)
    trained = YOLO(str(work / "runs" / "fold" / "weights" / "last.pt"))

    held = table[table["video_id"].isin(test)].copy()
    held["step"] = motion(held)
    rows = []
    for row in held.itertuples():
        src = frames_root / row.video_id / f"frame_{row.frame:04d}.jpg"
        result = trained.predict(str(src), imgsz=a.imgsz, conf=0.25, device="cpu", verbose=False)[0]
        h, w = result.orig_shape
        found = len(result.boxes) > 0
        error = np.nan
        if found and not np.isnan(row.x_center):
            best = result.boxes.xywhn[result.boxes.conf.argmax()].cpu().numpy()
            error = float(np.hypot((best[0] - row.x_center) * w, (best[1] - row.y_center) * h) / h)
        rows.append({"clip": row.video_id, "visible": not np.isnan(row.x_center), "found": found,
                     "error": error, "step": row.step})
    scored = pd.DataFrame(rows)

    def line(name, part):
        n = len(part)
        if n == 0:
            return f"| {name} | 0 | - | - | " + " | ".join("-" for _ in RADII) + " |"
        found = part[part["found"]]
        within = [f"{(found['error'] <= r).sum() / n:.0%}" for r in RADII]
        median = f"{found['error'].median():.3f}" if len(found) else "-"
        return f"| {name} | {n} | {len(found) / n:.0%} | {median} | " + " | ".join(within) + " |"

    visible = scored[scored["visible"]]
    hidden = scored[~scored["visible"]]
    lines = [f"### 自训杆头检测器（{a.model}，{a.imgsz}px）：测试 {', '.join(test)}", "",
             f"训练 {len(train)} 段（{len(table[table['video_id'].isin(train)])} 帧），测试 {len(test)} 段（{len(held)} 帧）。", "",
             "| 帧 | 数量 | 检出 | 误差中位数（画面高） | " + " | ".join(f"≤{r} 画面高" for r in RADII) + " |",
             "|---|---|---|---|" + "---|" * len(RADII), line("看得见杆头的全部帧", visible)]
    for name, lo, hi in BINS:
        lines.append(line(f"{name}（每帧位移 {lo}–{hi} 画面高）", visible[(visible["step"] >= lo) & (visible["step"] < hi)]))
    lines += [line(c, visible[visible["clip"] == c]) for c in test]
    lines += ["", f"标注为看不见杆头的帧 {len(hidden)} 帧，其中误检 {int(hidden['found'].sum())} 帧。"]
    text = "\n".join(lines) + "\n"
    print(text)
    if a.summary:
        Path(a.summary).write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
