"""How much of ClubheadDB can be rebuilt today, and do the rebuilt frames line up with its labels?

ClubheadDB (pip package clubhead-db, CC BY-NC 4.0) ships video links and one clubhead box per frame;
the frames themselves are downloaded from YouTube/Reddit with yt-dlp and cut with ffmpeg at the
listed frame rate. This script runs that download for every clip and compares, per clip, the number
of frames extracted with the number of labelled frames. Nothing is kept: run it in a scratch directory.

  python3 tools/club/clubheaddb_probe.py --work /tmp/clubheaddb --summary summary.md [--keep aligned/]

--keep copies the frames of every clip whose frame count matches its labels to <keep>/<clip>/,
for tools/club/clubheaddb_eval.py; keep that directory out of the repository.
"""
import argparse
import os
import shutil
import subprocess
from collections import Counter
from importlib import resources
from pathlib import Path

import pandas as pd


def labelled_counts():
    with resources.path("clubhead_db.data", "annotations.parquet") as path:
        table = pd.read_parquet(path)
    return table.groupby("video_id").size().to_dict()


def metadata():
    with resources.path("clubhead_db.data", "metadata.csv") as path:
        return pd.read_csv(path, delimiter=";")


def download(row, out):
    source, ident = str(row.source).strip(), str(row.youtube_id).strip()
    if source == "reddit":
        cmd = ["yt-dlp", "-q", "--no-warnings", "-o", str(out), ident]
    else:
        url = f"https://www.youtube.com/shorts/{ident}" if source == "yt_shorts" else f"https://www.youtube.com/watch?v={ident}"
        cmd = ["yt-dlp", "-q", "--no-warnings", "-f", "bestvideo[ext=mp4]",
               "--download-sections", f"*{row.start_time}-{row.end_time}", "--force-keyframes-at-cuts", "-o", str(out), url]
    done = subprocess.run(cmd, capture_output=True, text=True, timeout=600)
    if done.returncode != 0 or not out.exists():
        return (done.stderr or done.stdout).strip().splitlines()[-1][:160] if (done.stderr or done.stdout) else "no output"
    return None


def extract(video, frames, fps):
    frames.mkdir(parents=True, exist_ok=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(video), "-r", str(fps), "-q:v", "2", "-y",
                    str(frames / "frame_%04d.jpg")], check=True, timeout=600)
    return len(list(frames.glob("*.jpg")))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", required=True)
    ap.add_argument("--summary")
    ap.add_argument("--keep")
    a = ap.parse_args()
    work = Path(a.work)
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    labels = labelled_counts()
    rows, failures = [], Counter()
    for row in metadata().itertuples():
        if pd.isna(row.video_id) or pd.isna(row.youtube_id) or pd.isna(row.target_fps):
            continue
        video = work / f"{row.video_id}.mp4"
        error = download(row, video)
        extracted = None if error else extract(video, work / row.video_id, int(row.target_fps))
        expected = labels.get(row.video_id, 0)
        status = "失败" if error else ("对齐" if extracted == expected else "帧数不符")
        if error:
            failures[f"{row.source}: {error}"] += 1
        rows.append((row.video_id, row.source, row.playback_speed, expected, extracted, status))
        print(f"{row.video_id} {row.source} {status} {expected} {extracted}", flush=True)
        if a.keep and status == "对齐":
            shutil.copytree(work / row.video_id, Path(a.keep) / row.video_id, dirs_exist_ok=True)
        video.unlink(missing_ok=True)
        shutil.rmtree(work / row.video_id, ignore_errors=True)
    table = pd.DataFrame(rows, columns=["clip", "source", "speed", "labelled", "extracted", "status"])
    lines = ["### ClubheadDB 复现探查", "",
             f"段数 {len(table)}；对齐 {sum(table.status == '对齐')}，帧数不符 {sum(table.status == '帧数不符')}，下载失败 {sum(table.status == '失败')}",
             f"可用标注帧（对齐的段）{int(table[table.status == '对齐'].labelled.sum())} / {int(table.labelled.sum())}", "",
             "| 来源 | 段数 | 对齐 | 帧数不符 | 失败 |", "|---|---|---|---|---|"]
    for source, group in table.groupby("source"):
        lines.append(f"| {source} | {len(group)} | {sum(group.status == '对齐')} | {sum(group.status == '帧数不符')} | {sum(group.status == '失败')} |")
    lines += ["", "失败原因（yt-dlp 最后一行）：", ""] + [f"- {n} 段：{reason}" for reason, n in failures.most_common(8)]
    lines += ["", "| clip | source | speed | labelled | extracted | status |", "|---|---|---|---|---|---|"]
    lines += [f"| {r.clip} | {r.source} | {r.speed} | {r.labelled} | {r.extracted if r.extracted is not None else '-'} | {r.status} |"
              for r in table.itertuples()]
    text = "\n".join(lines) + "\n"
    print(text)
    if a.summary:
        Path(a.summary).write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
