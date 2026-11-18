"""Why does SwingNet find no phases on HD swing windows? (diagnostics only, numbers only)

On computer B, 29 of 77 YouTube HD swings got "没有识别出挥杆阶段" on the app's path (window ->
SwingNet -> SwingNetEventSelector). For each swing this prints the window (frames, fps, seconds,
size, orientation, person size), and runs SwingNet + the selector on four inputs:

  window     the app's window (swing_split.windows: 1 s before address, 1.5 s after impact, stretched)
  tight      address - 25% of the swing .. impact + 50% (no padding)
  window/k   the app's window with every k-th frame, k so that it fits one 64-frame chunk
  tight/k    the same for the tight cut

SwingNet's LSTM runs in independent 64-frame chunks (app and GolfDB eval alike), so a long slow-motion
window is several unrelated chunks whose argmaxes can come out of order. For each input: the
selector's result or the rule that failed (order = mid-back/top/mid-down/impact argmaxes not in
time order; no_address / no_finish; order2 = after filling address / finish), the chunk each of the
four argmaxes came from, and whether the top / impact found are within tolerance of the splitter's.

  python tools/camera/swingnet_why.py <hd report dir or results.json> [...] --names names.txt
  python tools/camera/swingnet_why.py --video niko_C.mov [--video ...]     (whole clip = the window)
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import tempfile
from collections import Counter
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
for d in ("tools/faults", "tools/robustness", "tools/split", "tools/benchmark"):
    sys.path.insert(0, str(ROOT / d))
from hd_reencode import read_cut, write_lossless  # noqa: E402
import swing_split  # noqa: E402

INTERIOR = (2, 3, 4, 5)  # mid-back, top, mid-down, impact


def select(probs: np.ndarray):
    """SwingNetEventSelector.keyframes with the failing rule named. -> (status, {event: frame})"""
    am = {e: int(np.argmax(probs[:, e])) for e in range(8)}
    times = dict(am)
    inter = [times[e] for e in INTERIOR]
    if not all(a < b for a, b in zip(inter, inter[1:])):
        return "order", am
    if times[0] >= inter[0]:
        c = [t for t in range(inter[0]) if probs[t, 0] > 0]
        if not c:
            return "no_address", am
        times[0] = max(c, key=lambda t: probs[t, 0])
    if times[7] <= inter[3]:
        c = [t for t in range(inter[3] + 1, len(probs)) if probs[t, 7] > 0]
        if not c:
            return "no_finish", am
        times[7] = max(c, key=lambda t: probs[t, 7])
    sel = [times[e] for e in (0, 2, 3, 4, 5, 7)]
    if not all(a < b for a, b in zip(sel, sel[1:])):
        return "order2", am
    return "ok", times


def run(model, frames, fps):
    from golfdb_eval import probabilities, read_frames
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "x.mkv"
        write_lossless(frames, fps, p)
        return probabilities(model, read_frames(p))


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("reports", type=Path, nargs="*")
    ap.add_argument("--names", type=Path)
    ap.add_argument("--video", type=Path, action="append", default=[])
    ap.add_argument("--limit", type=int, default=90)
    ap.add_argument("--max-frames", type=int, default=2000)
    ap.add_argument("--backend", choices=["numpy", "coreml"], default="numpy")
    ap.add_argument("--out", type=Path, default=Path("swingnet_why.json"))
    a = ap.parse_args()
    import cv2
    from golfdb_eval import load_model
    model = load_model(a.backend)

    jobs = []
    rows = []
    for rep in a.reports:
        f = rep / "results.json" if rep.is_dir() else rep
        if f.exists():
            rows += json.loads(f.read_text(encoding="utf-8"))
    if a.names:
        want = [x.strip() for x in a.names.read_text(encoding="utf-8-sig").split() if x.strip()]
        by = {r["name"]: r for r in rows}
        rows = [by[n] for n in want if n in by]
    for r in rows[:a.limit]:
        if r.get("phases") and r.get("video"):
            jobs.append((r["name"], r["video"], tuple(r["phases"]), r.get("lm"), r.get("verdict"), r.get("reason")))
    for v in a.video:
        jobs.append((v.stem, str(v), None, None, None, None))

    out, tally = [], Counter()
    for n, (name, video, phases, lmpath, verdict, reason) in enumerate(jobs, 1):
        cap = cv2.VideoCapture(video)
        cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
        fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
        total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        cap.release()
        rec = {"name": name, "fps": round(fps, 3), "pipeline": [verdict, reason]}
        cuts = {}
        if phases:
            ad, top, imp = phases
            (s0, e0), = swing_split.windows([phases], total, fps, single=True)
            sw = imp - ad
            t0, t1 = max(0, ad - sw // 4), min(total, imp + sw // 2 + 1)
            cuts = {"window": (s0, e0), "tight": (t0, t1)}
            rec.update(phases=list(phases), swing_frames=sw, swing_s=round(sw / fps, 2))
            if lmpath and Path(lmpath).exists():
                lm = np.load(lmpath)
                if ad < len(lm):
                    sh = np.nanmean(lm[ad, [11, 12], :2], 0)
                    hp = np.nanmean(lm[ad, [23, 24], :2], 0)
                    rec["torso_px"] = round(float(np.linalg.norm(sh - hp)), 1)
        else:
            cuts = {"window": (0, total)}
        lo = min(c[0] for c in cuts.values())
        hi = max(c[1] for c in cuts.values())
        if hi - lo > a.max_frames:
            print(f"{n}/{len(jobs)} {name}: {hi - lo} frames, skipped", flush=True)
            continue
        frames, _ = read_cut(video, lo, hi - 1)
        hgt, wid = frames[0].shape[:2]
        rec.update(size=[wid, hgt], landscape=wid > hgt)
        if "torso_px" in rec:
            rec["torso_frac"] = round(rec["torso_px"] / hgt, 3)
        rec["inputs"] = {}
        parts = []
        for cname, (c0, c1) in cuts.items():
            fr = frames[c0 - lo:c1 - lo]
            k = max(1, math.ceil(len(fr) / 64))
            for label, sub, step in ((cname, fr, 1), (f"{cname}/{k}", fr[::k], k)):
                if step == 1 or k > 1:
                    probs = run(model, sub, fps / step)
                    status, ev = select(probs)
                    chunks = [ev[e] // 64 for e in INTERIOR]
                    info = {"frames": len(sub), "seconds": round(len(fr) / fps, 2), "status": status,
                            "chunks": chunks, "top_p": round(float(probs[:, 3].max()), 3),
                            "impact_p": round(float(probs[:, 5].max()), 3)}
                    if status == "ok" and phases:
                        tol = max(1, round((imp - ad) / 30))
                        info["top_err"] = int(c0 + ev[3] * step - top)
                        info["impact_err"] = int(c0 + ev[5] * step - imp)
                        info["near"] = abs(info["top_err"]) <= tol * 2 and abs(info["impact_err"]) <= tol * 2
                    rec["inputs"][label] = info
                    tally[(label.split("/")[0] + ("/k" if "/" in label else ""), status)] += 1
                    parts.append(f"{label}[{len(sub)}f]={status}" + (f" ch{chunks}" if status != "ok" else
                                 f" top{info.get('top_err', '')} imp{info.get('impact_err', '')}"))
        out.append(rec)
        print(f"{n}/{len(jobs)} {name} {wid}x{hgt} {fps:.0f}fps swing {rec.get('swing_s', '?')}s "
              f"torso {rec.get('torso_frac', '?')} | " + " | ".join(parts), flush=True)
        a.out.write_text(json.dumps(out, ensure_ascii=False, indent=1, default=float), encoding="utf-8")

    print("\n| 输入 | ok | order | no_address | no_finish | order2 |")
    print("|---|---|---|---|---|---|")
    for label in ("window", "window/k", "tight", "tight/k"):
        cells = [tally[(label, s)] for s in ("ok", "order", "no_address", "no_finish", "order2")]
        if sum(cells):
            print(f"| {label} | " + " | ".join(map(str, cells)) + " |")
    fails = [o for o in out if o["inputs"].get("window", {}).get("status") not in (None, "ok")]
    oks = [o for o in out if o["inputs"].get("window", {}).get("status") == "ok"]

    def med(group, key, sub=None):
        xs = [(o["inputs"]["window"][key] if sub else o.get(key)) for o in group]
        xs = [x for x in xs if isinstance(x, (int, float))]
        return f"{np.median(xs):.2f}" if xs else "—"
    print("\n| App 窗口 | 杆数 | 窗口帧数中位 | 窗口秒数中位 | 杆时长中位（秒） | 人高占比（躯干/画面高）中位 | 横屏 |")
    print("|---|---|---|---|---|---|---|")
    for title, g in (("SwingNet 失败", fails), ("SwingNet 成功", oks)):
        print(f"| {title} | {len(g)} | {med(g, 'frames', 1)} | {med(g, 'seconds', 1)} | {med(g, 'swing_s')} | "
              f"{med(g, 'torso_frac')} | {sum(1 for o in g if o.get('landscape'))} |")
    near = [o for o in oks if o["inputs"]["window"].get("near") is False]
    print(f"\nSwingNet 成功但顶点/击球离切杆帧超过 2 倍容差：{len(near)}/{len(oks)}")


if __name__ == "__main__":
    main()
