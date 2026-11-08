"""How often does the App's person-crop SwingNet rerun fire, and are its phases right?

  python tools/benchmark/fallback_audit.py --golfdb <GolfDB data dir> --limit 400 --out fallback_audit
  python tools/benchmark/fallback_audit.py --videos <HD clip dir> --out fallback_audit_hd

For every clip: SwingNet on the whole frame (NumPy port, same selector as the App). Only when that
finds no phases: MediaPipe heavy pose -> PersonCrop -> SwingNet again on the crop (person_crop.py).
Writes <out>/audit.csv, <out>/summary.md and, for every clip where the rerun fired, <out>/sheets/
<name>.jpg: top and impact frames with two frames either side, to check by eye.
GolfDB clips are also scored against the labelled top / impact frames (|error| >= 5 frames = wrong).
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import cv2
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "tools" / "e2e"))
from golfdb_eval import load_model, probabilities, read_frames  # noqa: E402
from person_crop import estimate, phases_from_probs, read_frames_cropped  # noqa: E402


def pose_normalised(path: Path, model: Path):
    import mediapipe as mp
    from mediapipe.tasks import python as mpp
    from mediapipe.tasks.python import vision
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    opts = vision.PoseLandmarkerOptions(base_options=mpp.BaseOptions(model_asset_path=str(model)),
                                        running_mode=vision.RunningMode.VIDEO, num_poses=1)
    out = []
    with vision.PoseLandmarker.create_from_options(opts) as lm:
        i = 0
        while True:
            ok, img = cap.read()
            if not ok:
                break
            res = lm.detect_for_video(mp.Image(image_format=mp.ImageFormat.SRGB,
                                               data=cv2.cvtColor(img, cv2.COLOR_BGR2RGB)), int(i * 1000 / fps))
            out.append([[p.x, p.y, p.visibility, p.presence] for p in res.pose_landmarks[0]]
                       if res.pose_landmarks else [])
            i += 1
    cap.release()
    return out


def sheet(path: Path, phases, crop, out: Path, truth=None):
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    frames = []
    while True:
        ok, img = cap.read()
        if not ok:
            break
        frames.append(img)
    cap.release()
    rows = []
    for label, k in (("top", phases[1]), ("impact", phases[2])):
        tiles = []
        for f in range(k - 2, k + 3):
            if not 0 <= f < len(frames):
                tiles.append(np.zeros((240, 180, 3), np.uint8))
                continue
            img = frames[f].copy()
            H, W = img.shape[:2]
            x, y, w, h = crop
            cv2.rectangle(img, (int(x * W), int(y * H)), (int((x + w) * W), int((y + h) * H)), (0, 255, 255), 2)
            s = 240 / H
            img = cv2.resize(img, (max(1, int(W * s)), 240))
            txt = f"{label} {f}" + (" <" if f == k else "")
            cv2.putText(img, txt, (4, 20), 0, 0.6, (0, 0, 255) if f == k else (255, 255, 255), 2)
            tiles.append(img)
        rows.append(np.hstack(tiles))
    w = max(r.shape[1] for r in rows)
    rows = [cv2.copyMakeBorder(r, 0, 0, 0, w - r.shape[1], cv2.BORDER_CONSTANT) for r in rows]
    img = np.vstack(rows)
    if truth:
        cv2.putText(img, f"label top {truth[0]} impact {truth[1]}", (4, img.shape[0] - 8), 0, 0.6, (0, 255, 0), 2)
    cv2.imwrite(str(out), img)


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--golfdb", type=Path, help="GolfDB data dir (golfDB.pkl, videos_160/)")
    ap.add_argument("--view", default="down-the-line", help="GolfDB view filter ('' = all)")
    ap.add_argument("--limit", type=int, default=400)
    ap.add_argument("--videos", type=Path, help="folder of clips (mp4/mov), or a .txt list")
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    ap.add_argument("--out", type=Path, default=Path("fallback_audit"))
    a = ap.parse_args()
    (a.out / "sheets").mkdir(parents=True, exist_ok=True)

    jobs = []  # (name, path, (top, impact) labels or None)
    if a.golfdb:
        import pandas as pd
        df = pd.read_pickle(a.golfdb / "golfDB.pkl")
        if a.view:
            df = df[df["view"] == a.view]
        for row in df.head(a.limit).itertuples():
            ev = np.asarray(row.events) - row.events[0]
            jobs.append((f"golfdb_{row.id}", a.golfdb / "videos_160" / f"{row.id}.mp4", (int(ev[4]), int(ev[6]))))
    if a.videos:
        paths = ([Path(p.strip()) for p in a.videos.read_text(encoding="utf-8").splitlines() if p.strip()]
                 if a.videos.suffix == ".txt" else
                 sorted(p for p in a.videos.iterdir() if p.suffix.lower() in (".mp4", ".mov", ".m4v")))
        jobs += [(p.stem, p, None) for p in paths]

    model = load_model("numpy")
    rows = []
    for n, (name, path, truth) in enumerate(jobs, 1):
        if not path.exists():
            continue
        main_phases = phases_from_probs(probabilities(model, read_frames(path)))
        row = dict(name=name, main_phases=main_phases, fired=False, crop=None, crop_phases=None,
                   label_top=truth[0] if truth else None, label_impact=truth[1] if truth else None)
        if main_phases is None:
            crop = estimate(pose_normalised(path, a.model))
            row["fired"] = crop is not None
            row["crop"] = None if crop is None else [round(v, 3) for v in crop]
            if crop is not None:
                ph = phases_from_probs(probabilities(model, read_frames_cropped(path, crop)))
                row["crop_phases"] = ph
                if ph:
                    sheet(path, ph, crop, a.out / "sheets" / f"{name}.jpg", truth)
        final = row["main_phases"] or row["crop_phases"]
        if truth and final:
            row["top_err"], row["impact_err"] = final[1] - truth[0], final[2] - truth[1]
        rows.append(row)
        print(f"{n}/{len(jobs)} {name}: main {main_phases} fired {row['fired']} crop {row['crop_phases']}", flush=True)

    keys = ["name", "main_phases", "fired", "crop", "crop_phases", "label_top", "label_impact", "top_err", "impact_err"]
    with open(a.out / "audit.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, keys)
        w.writeheader()
        for r in rows:
            w.writerow({k: r.get(k) for k in keys})

    def stats(rs):
        e = [r for r in rs if "top_err" in r]
        bad = [r for r in e if abs(r["top_err"]) >= 5 or abs(r["impact_err"]) >= 5]
        return len(e), len(bad)
    fired = [r for r in rows if r["fired"]]
    got = [r for r in fired if r["crop_phases"]]
    lines = ["# 人物裁剪兜底审计", "",
             f"- 片段 {len(rows)}；主流程没找到阶段 {sum(r['main_phases'] is None for r in rows)}；"
             f"触发兜底（有人物框）{len(fired)}；兜底给出阶段 {len(got)}",
             ]
    n_all, bad_all = stats([r for r in rows if r["main_phases"]])
    n_fb, bad_fb = stats(got)
    if n_all:
        lines.append(f"- 主流程阶段 vs 标注：{n_all} 段里顶点或击球差 ≥5 帧的 {bad_all} 段")
    if n_fb:
        lines.append(f"- 兜底阶段 vs 标注：{n_fb} 段里顶点或击球差 ≥5 帧的 {bad_fb} 段（{bad_fb / n_fb:.0%}）")
    lines += ["", "兜底触发的每一段在 sheets/ 下有顶点、击球前后各两帧的截图（黄框 = 裁剪区域）。"]
    (a.out / "summary.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
