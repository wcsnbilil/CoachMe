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

Three ways to pick one clubhead per frame from the detector's boxes are compared, all fixed before
looking at the held-out golfers:
  top1    the most confident box at conf >= 0.25 (what a plain detector does);
  viterbi one path through each clip over every box at conf >= 0.05 plus a "not visible" state:
          a box costs -log(conf), "not visible" costs -log(0.25), moving d frame heights between
          frames costs d / 0.1, entering or leaving "not visible" costs 1;
  hands   viterbi, and a box more than 3 torso lengths from the hands (MediaPipe, --poses) is ruled
          out, since the clubhead cannot be farther from the hands than the club is long.
"""
import argparse
import os
import shutil
import warnings
from importlib import resources
from pathlib import Path

import numpy as np
import pandas as pd

RADII = (0.02, 0.05)
BINS = (("静止", 0.0, 0.005), ("移动", 0.005, 0.03), ("快速", 0.03, np.inf))
TOP1_CONF, CANDIDATE_CONF, HIDDEN_CONF = 0.25, 0.05, 0.25
STEP_SCALE, SWITCH_COST, REACH_TORSOS = 0.1, 1.0, 3.0
HANDS = (15, 16, 19, 20)
SHOULDERS, HIPS = (11, 12), (23, 24)


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


def pose(path):
    if path is None or not path.exists():
        return {}, np.nan
    data = np.load(path)
    lm = data["landmarks"].astype(float)
    lm[~(lm[:, :, 2] >= 0.5), :2] = np.nan
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", RuntimeWarning)
        hands = np.nanmean(lm[:, HANDS, :2], axis=1)
        torso = np.nanmedian(np.linalg.norm(np.nanmean(lm[:, SHOULDERS, :2], 1) - np.nanmean(lm[:, HIPS, :2], 1), axis=1))
    return {int(f): hands[i] for i, f in enumerate(data["frame"]) if np.all(np.isfinite(hands[i]))}, float(torso)


def reachable(xy, conf, hand, torso, height):
    if hand is None or not np.isfinite(torso) or len(xy) == 0:
        return xy, conf
    keep = np.linalg.norm(xy - hand / height, axis=1) <= REACH_TORSOS * torso / height
    return xy[keep], conf[keep]


def viterbi(frames):
    """frames: per frame (xy in frame heights, conf). Returns per frame the chosen xy or None."""
    hidden = -np.log(HIDDEN_CONF)
    cost, back = None, []
    for xy, conf in frames:
        emit = np.concatenate([[hidden], -np.log(np.clip(conf, 1e-6, 1.0))])
        if cost is None:
            cost, back = emit, [np.zeros(len(emit), int)]
            prev = xy
            continue
        trans = np.full((len(cost), len(emit)), SWITCH_COST)
        trans[0, 0] = 0.0
        if len(prev) and len(xy):
            trans[1:, 1:] = np.linalg.norm(prev[:, None, :] - xy[None, :, :], axis=2) / STEP_SCALE
        total = cost[:, None] + trans
        back.append(total.argmin(axis=0))
        cost = total.min(axis=0) + emit
        prev = xy
    state, path = int(cost.argmin()), []
    for t in range(len(frames) - 1, -1, -1):
        path.append(None if state == 0 else frames[t][0][state - 1])
        state = int(back[t][state])
    return path[::-1]


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
    ap.add_argument("--poses", help="clubheaddb_pose.py --out dir for the held-out clips")
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
    for clip, part in held.groupby("video_id"):
        hands, torso = pose(Path(a.poses) / f"{clip}.npz" if a.poses else None)
        boxes = []
        for row in part.itertuples():
            src = frames_root / row.video_id / f"frame_{row.frame:04d}.jpg"
            result = trained.predict(str(src), imgsz=a.imgsz, conf=CANDIDATE_CONF, device="cpu", verbose=False)[0]
            h, w = result.orig_shape
            xy = result.boxes.xywhn[:, :2].cpu().numpy() * [w / h, 1.0]
            boxes.append((xy, result.boxes.conf.cpu().numpy(), hands.get(row.frame), w / h, h))
        picks = {
            "top1": [(xy[c.argmax()] if len(c) and c.max() >= TOP1_CONF else None) for xy, c, *_ in boxes],
            "viterbi": viterbi([(xy, c) for xy, c, *_ in boxes]),
            "hands": viterbi([reachable(xy, c, hand, torso, h) for xy, c, hand, _, h in boxes]),
        }
        for i, row in enumerate(part.itertuples()):
            visible = not np.isnan(row.x_center)
            aspect, height = boxes[i][3], boxes[i][4]
            for name, chosen in picks.items():
                pick = chosen[i]
                error = np.nan
                if pick is not None and visible:
                    error = float(np.hypot(pick[0] - row.x_center * aspect, pick[1] - row.y_center))
                rows.append({"decoder": name, "clip": clip, "visible": visible, "found": pick is not None,
                             "error": error, "step": row.step, "height": height})
    scored = pd.DataFrame(rows)

    def cells(part):
        n = len(part)
        if n == 0:
            return ["0", "-"] + ["-" for _ in RADII]
        found = part[part["found"]]
        return [str(n), f"{len(found) / n:.0%}"] + [f"{(found['error'] <= r).sum() / n:.0%}" for r in RADII]

    def binned(visible, lo, hi):
        return visible[(visible["step"] >= lo) & (visible["step"] < hi)]

    head = "| 挑法 | 帧 | 数量 | 检出 | " + " | ".join(f"≤{r} 画面高" for r in RADII) + " |"
    rule = "|---|---|---|---|" + "---|" * len(RADII)
    lines = [f"### 自训杆头检测器（{a.model}，{a.imgsz}px）：测试 {', '.join(test)}", "",
             f"训练 {len(train)} 段（{len(table[table['video_id'].isin(train)])} 帧），测试 {len(test)} 段（{len(held)} 帧）。"
             + ("" if a.poses else "没有 --poses，hands 等于 viterbi。"), "", head, rule]
    for name in ("top1", "viterbi", "hands"):
        mine = scored[scored["decoder"] == name]
        visible = mine[mine["visible"]]
        lines.append(f"| {name} | 看得见杆头的全部帧 | " + " | ".join(cells(visible)) + " |")
        for label, lo, hi in BINS:
            lines.append(f"| {name} | {label}（每帧位移 {lo}–{hi}） | " + " | ".join(cells(binned(visible, lo, hi))) + " |")
        lines += [f"| {name} | {c} | " + " | ".join(cells(visible[visible["clip"] == c])) + " |" for c in test]
    lines += ["", "| 挑法 | 标注为看不见杆头的帧 | 误检 |", "|---|---|---|"]
    for name in ("top1", "viterbi", "hands"):
        hidden = scored[(scored["decoder"] == name) & ~scored["visible"]]
        lines.append(f"| {name} | {len(hidden)} | {int(hidden['found'].sum())} |")
    text = "\n".join(lines) + "\n"
    print(text)
    if a.summary:
        Path(a.summary).write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
