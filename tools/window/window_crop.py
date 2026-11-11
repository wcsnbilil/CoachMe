"""Does cutting a swing out of a longer clip change the verdict? (GolfDB, labelled phases.)

Since #13 the app analyses only the window around the chosen swing when a clip is long: the frames
from PAD_BEFORE_S before address to PAD_AFTER_S after impact (stretched for slow motion), with a fresh
MediaPipe tracker that starts at the window's first frame. On computer B, cutting HD swings out of
their source video changed about 6 of 29 verdicts before any re-encoding. This measures the same
thing on GolfDB: the whole clip vs a cut, same pixels, same labelled phases (shifted into the cut).

  --variant whole        pose on the whole clip (the reference); saves the landmarks for the others
  --variant app          the app's window (swing_split.windows around the labelled swing)
  --variant split        the app's window around the swing swing_split.find_swings finds on the
                         whole-clip landmarks (address / impact from the splitter, not the labels)
  --variant lead0.5 ...  cut that many seconds before address (stress test: less tracker warm-up)
  --variant warmN        app window, but the tracker sees N extra frames before it (warm-up frames,
                         not analysed): the fix to try if cuts flip too often. Parts combine with "+":
                         lead0.25+warm30 = cut 0.25 s before address, tracker starts 30 frames earlier

  --variant joined       the app's real path: GolfDB clips (same speed: real-time or slow motion)
                         joined 4 at a time into one > 8 s video, each clip held still for 1.5-3 s
                         before and 1-2 s after (a range session with pauses). A 15 fps scout pass
                         over the whole joined video, swing_split.find_swings + windows(single=True)
                         as BetaAnalysisRunner.swingWindows, then a fresh tracker on each window.
                         Each swing is compared with its own clip analysed whole.

A clip whose window is the whole clip keeps the whole-clip landmarks (MediaPipe is deterministic on
the same frames, PR #15), so only real cuts are re-run. For every cut clip the per-frame distance
between the cut's and the whole clip's hands / shoulders (torso lengths) is kept, to see whether the
tracker needs a warm-up after a cut.

Writes <out>/results.json in run_path format (+ window, cut, warm) and, for --variant whole,
<out>/landmarks/<name>.npy. Numbers only: no frames are written.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
sys.path.insert(0, str(ROOT / "tools" / "split"))
from path_fault import analyze  # noqa: E402
from run_path import pose_landmarks, read_video  # noqa: E402
import swing_split  # noqa: E402

LW, RW, LS, RS, LH, RH = 15, 16, 11, 12, 23, 24


def golfdb_jobs(root: Path, limit: int):
    import pandas as pd
    df = pd.read_pickle(root / "golfDB.pkl")
    df = df[df["view"] == "down-the-line"].head(limit)
    for row in df.itertuples():
        ev = np.asarray(row.events) - row.events[0]
        yield (f"golfdb_{row.id}", root / "videos_160" / f"{row.id}.mp4", (int(ev[1]), int(ev[4]), int(ev[6])),
               {"id": int(row.id), "player": row.player, "slow": int(row.slow), "youtube_id": row.youtube_id})


def window_for(variant: str, phases, n: int, fps: float, whole_lm: np.ndarray | None):
    """(start, end, tracker_start): analyse frames [start, end); the tracker starts at tracker_start <= start."""
    ad, top, imp = phases
    if variant == "split":
        found = swing_split.find_swings(whole_lm, fps) if whole_lm is not None else []
        # the found swing whose top is nearest the labelled top
        if not found:
            return None
        sw = min(found, key=lambda s: abs(s[1] - top))
        w = swing_split.windows([sw], n, fps, single=True)
    else:
        w = swing_split.windows([phases], n, fps, single=True)
    start, end = w[0]
    warm = 0
    for part in variant.split("+"):  # e.g. "lead0.25+warm30"
        if part.startswith("lead"):
            start = max(0, ad - int(round(float(part[4:]) * fps)))
        elif part.startswith("warm"):
            warm = int(part[4:])
    return start, end, max(0, start - warm)


def warm_diff(cut: np.ndarray, ref: np.ndarray) -> list[float]:
    """Per frame of the cut: max distance (px) over hands-mid and shoulders-mid vs the whole clip."""
    out = []
    for c, r in zip(cut, ref):
        ds = []
        for a, b in ((LW, RW), (LS, RS)):
            if np.isfinite(c[[a, b], :2]).all() and np.isfinite(r[[a, b], :2]).all():
                ds.append(float(np.linalg.norm(c[[a, b], :2].mean(0) - r[[a, b], :2].mean(0))))
        out.append(round(max(ds), 2) if ds else None)
    return out


def torso_px(lm: np.ndarray, f: int) -> float | None:
    sh, hip = lm[f, [LS, RS], :2].mean(0), lm[f, [LH, RH], :2].mean(0)
    d = float(np.linalg.norm(sh - hip))
    return d if np.isfinite(d) and d > 1 else None


SCOUT_FPS = 15.0  # BetaAnalysisRunner.scoutFramesPerSecond
SPLIT_MIN_S = 8.0  # BetaAnalysisRunner.splitMinimumSeconds


def joined_results(jobs, model: Path, whole_dir: Path | None, group: int = 4, seed: int = 7) -> list[dict]:
    import random
    rng = random.Random(seed)
    out = []
    for slow in (0, 1):
        clips = [j for j in jobs if j[3].get("slow") == slow and j[1].exists()]
        for g in range(0, len(clips), group):
            part = clips[g:g + group]
            frames, spans = [], []
            fps = None
            for name, path, phases, extra in part:
                fr, f = read_video(path)
                fps = fps or f
                pre, post = int(rng.uniform(1.5, 3.0) * fps), int(rng.uniform(1.0, 2.0) * fps)
                off = len(frames) + pre
                frames += [fr[0]] * pre + fr + [fr[-1]] * post
                spans.append((name, phases, extra, off, len(fr)))
            n = len(frames)
            step = max(1, int(round(fps / SCOUT_FPS)))
            sfps = fps / step
            scout = pose_landmarks(frames[::step], sfps, model)
            found = swing_split.find_swings(scout, sfps)
            wins = swing_split.windows(found, len(scout), sfps, single=True)
            # scout frames -> video frames, like swingWindows (timestamps)
            vwins = [(s0 * step, min(n, e0 * step)) for s0, e0 in wins]
            info = dict(joined_frames=n, joined_seconds=round(n / fps, 1), swings_found=len(found),
                        swings_joined=len(part))
            for name, phases, extra, off, length in spans:
                ad, top, imp = (p + off for p in phases)
                # the window whose swing top is nearest this clip's labelled top
                best = None
                for (s0, e0), sw in zip(vwins, found):
                    d = abs(sw[1] * step - top)
                    if s0 <= ad and imp < e0 and (best is None or d < best[0]):
                        best = (d, s0, e0)
                if n / fps <= SPLIT_MIN_S:
                    r = {"verdict": "skip", "reason": "拼起来不到 8 秒，App 不会切"}
                elif best is None:
                    r = {"verdict": "skip", "reason": "切分没有找到包住这一杆的窗口"}
                else:
                    _, s0, e0 = best
                    lm = pose_landmarks(frames[s0:e0], fps, model)
                    r = analyze(lm, ad - s0, top - s0, imp - s0)
                    r.update(window=[s0 - off, e0 - off], cut=True)
                    if whole_dir and (whole_dir / f"{name}.npy").exists():
                        wl = np.load(whole_dir / f"{name}.npy").astype(float)
                        lo, hi = max(s0, off), min(e0, off + length)
                        r["warm"] = [None] * (lo - s0) + warm_diff(lm[lo - s0:hi - s0], wl[lo - off:hi - off])
                        r["torso_px_whole"] = torso_px(wl, phases[0])
                r = {kk: v for kk, v in r.items() if kk != "hands"}
                r.update(name=name, phases=list(phases), perturb="joined", frames=length, fps=round(fps, 3),
                         **info, **extra)
                out.append(r)
                print(f"joined {name}: {r['verdict']} {r.get('offset', '')} {r.get('reason', '')} "
                      f"window={r.get('window')} found={len(found)}/{len(part)}", flush=True)
    return out


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--golfdb", type=Path, required=True)
    ap.add_argument("--limit", type=int, default=400)
    ap.add_argument("--variant", default="app")
    ap.add_argument("--whole", type=Path, help="landmarks folder written by --variant whole")
    ap.add_argument("--model", type=Path, default=ROOT / "CoachMe" / "Resources" / "pose_landmarker_heavy.task")
    ap.add_argument("--out", type=Path, default=Path("window_crop"))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    lmdir = a.out / "landmarks"
    if a.variant == "whole":
        lmdir.mkdir(exist_ok=True)
    results = []
    jobs = list(golfdb_jobs(a.golfdb, a.limit))
    if a.variant == "joined":
        results = joined_results(jobs, a.model, a.whole)
        jobs = []
    for k, (name, path, phases, extra) in enumerate(jobs, 1):
        if not path.exists():
            continue
        frames, fps = read_video(path)
        n = len(frames)
        whole = None
        if a.whole and (a.whole / f"{name}.npy").exists():
            whole = np.load(a.whole / f"{name}.npy").astype(float)
        if a.variant == "whole":
            whole = pose_landmarks(frames, fps, a.model)
            np.save(lmdir / f"{name}.npy", whole.astype(np.float32))
            r = analyze(whole, *phases)
            r.update(window=[0, n], cut=False)
        else:
            w = window_for(a.variant, phases, n, fps, whole)
            ad, top, imp = phases
            if w is None or not (w[0] <= ad and imp < w[1]):
                r = {"verdict": "skip", "reason": "窗口没包含标注的整段挥杆", "window": list(w[:2]) if w else None}
            else:
                start, end, tr = w
                if (tr, end) == (0, n) and whole is not None:
                    lm, cut = whole, False
                else:
                    full = pose_landmarks(frames[tr:end], fps, a.model)
                    lm, cut = full[start - tr:], True
                r = analyze(lm, ad - start, top - start, imp - start)
                r.update(window=[start, end], tracker_start=tr, cut=cut)
                if cut and whole is not None:
                    r["warm"] = warm_diff(lm, whole[start:end])
                    r["torso_px_whole"] = torso_px(whole, ad)
        r = {kk: v for kk, v in r.items() if kk != "hands"}
        r.update(name=name, phases=list(phases), perturb=a.variant, frames=n, fps=round(fps, 3), **extra)
        results.append(r)
        print(f"{k}/{len(jobs)} {name}: {r['verdict']} {r.get('offset', '')} {r.get('reason', '')} "
              f"window={r.get('window')} cut={r.get('cut')}", flush=True)
    (a.out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1, default=float),
                                        encoding="utf-8")


if __name__ == "__main__":
    main()
