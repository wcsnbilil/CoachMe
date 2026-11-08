"""Track the club (shaft + head) through a down-the-line swing and measure the classic P6 check.

Needs a run_path.py report for the same videos (pose landmarks + address/top/impact):
  python tools/faults/run_path.py --video a.mp4 --video b.mp4 --out report
  python tools/club/club_track.py report --videos-dir <dir with the same .mp4 files> --out club_report

How it works
1. Address frame: find the shaft as the longest straight edge that starts at the hands and runs down
   toward the ball (Hough on Canny edges). Its far end is the clubhead at address.
2. SAM 2 (ultralytics, GPU if available) is prompted with two points on that shaft (+ negatives on
   the body) and propagates the club mask through address -> impact.
3. Per frame: clubhead = mask pixel farthest from the hands; shaft = hands -> clubhead.
4. P6 = first downswing frame where the hands drop to hip height. Coaches' down-the-line check:
   clubhead outside the hands (ball side) = steep / over the top; behind the hands = shallow / inside.
   `p6_head_offset` = (clubhead - hands) along the ball direction / torso length (+ = outside = steep).
   `p6_plane_deg` = shaft angle at P6 minus address shaft angle (+ = steeper than the address plane).
Output: <out>/<name>.jpg (address / top / P6 / impact with the club drawn), <out>/<name>.npz
(per-frame head/hands, for auto-labelling), <out>/results.json, <out>/index.html.
"""
from __future__ import annotations

import argparse
import html
import json
import math
import sys
from pathlib import Path

import cv2
import numpy as np

LW, RW, LI, RI, LS, RS, LH, RH, LK, RK = 15, 16, 19, 20, 11, 12, 23, 24, 25, 26


def mid(lm, f, a, b):
    return np.nanmean(lm[f, [a, b], :2], 0)


def hands_at(lm, f):
    return np.nanmean(lm[f, [LW, RW, LI, RI], :2], 0)


def read_range(path: Path, lo: int, hi: int):
    cap = cv2.VideoCapture(str(path))
    cap.set(cv2.CAP_PROP_POS_FRAMES, lo)
    out = []
    for _ in range(lo, hi + 1):
        ok, img = cap.read()
        if not ok:
            break
        out.append(img)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    cap.release()
    return out, fps


def address_shaft(img, hands, torso):
    """Longest straight edge starting near the hands and going down. Returns (head_xy, line) or None."""
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    g = cv2.GaussianBlur(g, (3, 3), 0)
    e = cv2.Canny(g, 40, 120)
    lines = cv2.HoughLinesP(e, 1, np.pi / 360, threshold=30, minLineLength=int(0.45 * torso), maxLineGap=int(0.08 * torso) + 2)
    best, score = None, 0.0
    for x1, y1, x2, y2 in (lines[:, 0] if lines is not None else []):
        p, q = np.array([x1, y1], float), np.array([x2, y2], float)
        if p[1] > q[1]:
            p, q = q, p  # p = upper end
        d = q - p
        L = np.linalg.norm(d)
        if L < 1 or d[1] / L < 0.35:  # must point clearly downward
            continue
        # distance from hands to the infinite line and to the upper end
        n = np.array([-d[1], d[0]]) / L
        if abs(np.dot(hands - p, n)) > 0.12 * torso or np.linalg.norm(hands - p) > 0.6 * torso:
            continue
        if q[1] - hands[1] < 0.5 * torso or L > 2.6 * torso:
            continue
        s = L - 2 * abs(np.dot(hands - p, n))
        if s > score:
            best, score = (p, q), s
    if best is None:
        return None
    p, q = best
    u = (q - p) / np.linalg.norm(q - p)
    t = np.dot(q - hands, u)  # head = far end measured from the hands along the shaft
    return hands + u * t, (p, q)


def run_sam(frames, points, labels, model):
    from ultralytics.models.sam import SAM2VideoPredictor
    import tempfile
    h, w = frames[0].shape[:2]
    tmp = Path(tempfile.mkdtemp()) / "clip.mp4"
    vw = cv2.VideoWriter(str(tmp), cv2.VideoWriter_fourcc(*"mp4v"), 30, (w, h))
    for f in frames:
        vw.write(f)
    vw.release()
    pred = SAM2VideoPredictor(overrides=dict(conf=0.25, task="segment", mode="predict", imgsz=1024,
                                             model=model, verbose=False, save=False))
    masks = []
    for r in pred(source=str(tmp), points=[points], labels=[labels], stream=True):
        if r.masks is None or len(r.masks.data) == 0:
            masks.append(None)
        else:
            m = r.masks.data.any(0).cpu().numpy()
            if m.shape != (h, w):
                m = cv2.resize(m.astype(np.uint8), (w, h), interpolation=cv2.INTER_NEAREST) > 0
            masks.append(m)
    return masks


def head_from_mask(m, hands, torso):
    if m is None:
        return None
    ys, xs = np.nonzero(m)
    if len(xs) < 20:
        return None
    pts = np.stack([xs, ys], 1).astype(float)
    d = np.linalg.norm(pts - hands, axis=1)
    far = d >= np.percentile(d, 99)
    head = pts[far].mean(0)
    L = np.linalg.norm(head - hands)
    if L < 0.4 * torso or L > 2.8 * torso:
        return None
    return head


def angle(v):
    return math.degrees(math.atan2(-v[1], abs(v[0]) + 1e-9))  # elevation above horizontal, 0..90 for a down-pointing shaft -> negative


def main():
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("report", type=Path, help="run_path.py --out dir (results.json + landmarks/)")
    ap.add_argument("--videos-dir", type=Path, help="for run_path.py reports (hd_pipeline.py rows carry their video path)")
    ap.add_argument("--out", type=Path, default=Path("club_report"))
    ap.add_argument("--model", default="sam2_b.pt")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--accepted", action="store_true", help="only swings path_fault did not refuse")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    rows = json.loads((a.report / "results.json").read_text(encoding="utf-8"))
    results = []
    for r in rows:
        name = r["name"]
        if a.only and name not in a.only:
            continue
        if a.accepted and r.get("verdict") == "无法判断":
            continue
        if a.limit and len(results) >= a.limit:
            break
        npy = Path(r["lm"]) if r.get("lm") else a.report / "landmarks" / f"{name}.npy"
        vid = Path(r["video"]) if r.get("video") else (a.videos_dir or Path(".")) / f"{name}.mp4"
        if not r.get("phases") or not npy.exists() or not vid.exists():
            continue
        res = {"name": name, "path_verdict": r.get("verdict"), "path_offset": r.get("offset")}
        lm = np.load(npy).astype(float)
        lm[~(lm[:, :, 2] >= 0.5), :2] = np.nan
        ad, top, imp = r["phases"]
        end = min(len(lm) - 1, imp + max(2, (imp - ad) // 10))
        frames, _ = read_range(vid, ad, end)
        if len(frames) < imp - ad:
            res["status"] = "视频帧不够"; results.append(res); continue
        hands0 = hands_at(lm, ad)
        torso = float(np.linalg.norm(mid(lm, ad, LS, RS) - mid(lm, ad, LH, RH)))
        if not np.all(np.isfinite(hands0)) or not np.isfinite(torso) or torso < 20:
            res["status"] = "准备姿势关键点缺失"; results.append(res); continue
        found = address_shaft(frames[0], hands0, torso)
        if found is None:
            res["status"] = "准备姿势找不到杆身"
            cv2.imwrite(str(a.out / f"{name}.jpg"), frames[0]); results.append(res); continue
        head0, _ = found
        side = 1 if head0[0] > hands0[0] else -1
        pos = [list(hands0 + (head0 - hands0) * t) for t in (0.4, 0.75)]
        neg = [list(mid(lm, ad, LH, RH)), list(mid(lm, ad, LK, RK))]
        neg = [p for p in neg if np.all(np.isfinite(p))]
        masks = run_sam(frames, pos + neg, [1, 1] + [0] * len(neg), a.model)
        n = len(masks)
        heads = np.full((n, 2), np.nan)
        handsT = np.full((n, 2), np.nan)
        for i in range(n):
            hh = hands_at(lm, ad + i)
            handsT[i] = hh
            if np.all(np.isfinite(hh)):
                h = head_from_mask(masks[i], hh, torso)
                if h is not None:
                    heads[i] = h
        ok = np.isfinite(heads[:, 0])
        res.update(side=side, torso=round(torso, 1), frames=n, tracked=round(float(ok.mean()), 3),
                   tracked_downswing=round(float(ok[top - ad:imp - ad + 1].mean()), 3))
        # P6: first frame after top where hands reach hip height
        hip_y = mid(lm, ad, LH, RH)[1]
        p6 = None
        for i in range(top - ad, imp - ad + 1):
            if np.isfinite(handsT[i, 1]) and handsT[i, 1] >= hip_y - 0.15 * torso:
                p6 = i; break
        a0 = angle(head0 - hands0)
        res["address_shaft_deg"] = round(-a0, 1)
        if p6 is not None:
            # nearest tracked frame within +-2
            cand = [j for j in range(p6 - 2, p6 + 3) if 0 <= j < n and ok[j]]
            if cand:
                j = min(cand, key=lambda j: abs(j - p6))
                v = heads[j] - handsT[j]
                res["p6_frame"] = ad + j
                res["p6_head_offset"] = round(float(v[0] * side / torso), 3)
                res["p6_plane_deg"] = round(float(abs(angle(v)) - abs(a0)), 1)
        res["status"] = "ok" if "p6_head_offset" in res else "P6 杆头没跟上"
        # drawing
        tiles = []
        for lab, i in (("address", 0), ("top", top - ad), ("P6", res.get("p6_frame", ad + (p6 or 0)) - ad), ("impact", imp - ad)):
            i = int(np.clip(i, 0, n - 1))
            im = frames[i].copy()
            if masks[i] is not None:
                im[masks[i]] = (0.5 * im[masks[i]] + [0, 0, 127]).astype(np.uint8)
            p0 = hands0.astype(int); q0 = (hands0 + (head0 - hands0) * 3).astype(int)
            cv2.line(im, tuple(p0), tuple(2 * p0 - q0), (0, 255, 0), 2)  # address plane, extended up
            cv2.line(im, tuple(p0), tuple(head0.astype(int)), (0, 255, 0), 2)
            if ok[i]:
                cv2.line(im, tuple(handsT[i].astype(int)), tuple(heads[i].astype(int)), (0, 255, 255), 3)
                cv2.circle(im, tuple(heads[i].astype(int)), 7, (0, 255, 255), 2)
            cv2.putText(im, lab, (10, 30), cv2.FONT_HERSHEY_SIMPLEX, 1, (255, 255, 255), 2)
            tiles.append(cv2.resize(im, (int(im.shape[1] * 360 / im.shape[0]), 360)))
        cv2.imwrite(str(a.out / f"{name}.jpg"), np.hstack(tiles), [cv2.IMWRITE_JPEG_QUALITY, 85])
        np.savez_compressed(a.out / f"{name}.npz", start=ad, heads=heads, hands=handsT, side=side, torso=torso)
        print(name, res["status"], res.get("p6_head_offset"), res.get("p6_plane_deg"), "tracked", res["tracked_downswing"], flush=True)
        results.append(res)
    (a.out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=1), encoding="utf-8")
    cards = "".join(
        f"<figure><img src='{html.escape(r['name'])}.jpg'><figcaption>{html.escape(r['name'])} {html.escape(r.get('status', ''))} "
        f"P6 杆头偏移={r.get('p6_head_offset', '—')} 平面差={r.get('p6_plane_deg', '—')}° 下杆跟踪={r.get('tracked_downswing', '—')} "
        f"手路径={html.escape(str(r.get('path_verdict')))} {r.get('path_offset', '')}</figcaption></figure>"
        for r in sorted(results, key=lambda r: -(r.get("p6_head_offset") if r.get("p6_head_offset") is not None else -9)))
    (a.out / "index.html").write_text(
        "<meta charset=utf-8><title>杆身跟踪</title><style>body{font:14px sans-serif;margin:16px}img{max-width:100%}"
        "figure{margin:10px 0}</style><h1>杆身 / 杆头跟踪</h1><p>绿线=准备姿势杆身平面（向上延长），黄线=当前帧双手→杆头，红色=SAM 2 球杆掩膜。"
        "P6 杆头偏移 &gt;0 = 杆头在双手外侧（陡/外下），&lt;0 = 在双手后面（平/内下）。</p>" + cards, encoding="utf-8")
    print(len(results), "clips ->", a.out / "index.html")


if __name__ == "__main__":
    main()
