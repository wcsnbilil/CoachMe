"""Week-1 club labels: per frame 4 club points from the SAM 2 club mask (club_track + club_track2 v2 address finder / SAM).
  grip_end : shaft end on the hands side (butt of the grip)
  hosel    : where the shaft meets the clubhead (mask widens)
  toe, heel: clubhead extremes along the head blob's long axis, heel = the end nearer the hosel
             (only for frames within +-TH of impact, per spec; elsewhere null)
Output per swing: <out>/<name>.club4.json (frame -> points + quality) and <name>_check.jpg (5 sampled frames for manual check).
usage: python club4.py REPORT_DIR [REPORT_DIR ...] --out DIR [--only name ...] [--limit N]"""
import argparse, json, os, sys
from pathlib import Path
import cv2, numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import club_track2  # noqa: F401  (patches club_track: v2 address finder + SAM combo)
import club_track as ct

TH = 4  # frames either side of impact that get toe/heel


def pca(P):
    mu = P.mean(0); ev, evec = np.linalg.eigh(np.cov((P - mu).T))
    return mu, evec[:, 1], evec[:, 0], np.sqrt(np.maximum(ev, 0))


def four_points(m, hands, torso, want_head):
    if m is None: return None
    ys, xs = np.nonzero(m)
    if len(xs) < 30: return None
    P = np.column_stack([xs, ys]).astype(float)
    # main axis from the thin (shaft) part: drop the widest 15% (clubhead) by iterating once
    mu, ax, nr, sd = pca(P)
    # a club mask is a thin line (plus a small head); a leg / trouser mask is a fat blob
    if sd[1] < 6 * sd[0] or len(P) > 0.25 * torso ** 2: return None
    t = (P - mu) @ ax
    if np.dot(hands - mu, ax) > 0: ax, t = -ax, -t  # +t points away from the hands, toward the clubhead
    w = (P - mu) @ nr
    tmin, tmax = np.percentile(t, 0.5), np.percentile(t, 99.5)
    L = tmax - tmin
    if L < 0.5 * torso or L > 3.2 * torso: return None
    grip = mu + ax * tmin + nr * np.median(w[t < tmin + 0.05 * L])
    # width profile along the axis -> hosel where the width jumps near the head end
    bins = np.linspace(tmin, tmax, 41); widths = []
    for a, b in zip(bins[:-1], bins[1:]):
        sel = (t >= a) & (t < b)
        widths.append(np.ptp(w[sel]) if sel.sum() > 2 else np.nan)
    widths = np.array(widths); base = np.nanmedian(widths[5:30]) if np.isfinite(widths[5:30]).any() else np.nan
    k = None
    if np.isfinite(base):
        for i in range(20, 40):
            if np.isfinite(widths[i]) and widths[i] > 2.2 * max(base, 2.0):
                k = i; break
    if k is None:  # no visible head widening (head edge-on or not segmented): hosel = far end
        hosel = mu + ax * tmax + nr * np.median(w[t > tmax - 0.03 * L]); head = None
    else:
        th = bins[k]
        hosel = mu + ax * th + nr * np.median(w[(t > th - 0.06 * L) & (t < th)])
        head = P[t >= th]
    out = {"grip_end": grip.tolist(), "hosel": hosel.tolist(), "toe": None, "heel": None,
           "len_torso": round(float(L / torso), 3), "head_seen": head is not None}
    if want_head and head is not None and len(head) >= 15:
        hm, hax, _, _ = pca(head)
        s = (head - hm) @ hax
        e1, e2 = head[np.argmin(s)], head[np.argmax(s)]
        heel, toe = (e1, e2) if np.linalg.norm(e1 - hosel) < np.linalg.norm(e2 - hosel) else (e2, e1)
        out["toe"], out["heel"] = toe.tolist(), heel.tolist()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report", type=Path, nargs="+"); ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--only", nargs="*"); ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--model", default=str(Path(r"C:\Users\49907\coachme-bench\coachme\sam2_b.pt")))
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    rows = []
    for rep in a.report:
        if (rep / "results.json").exists():
            rows += [dict(r, _rep=rep) for r in json.loads((rep / "results.json").read_text(encoding="utf-8"))]
    done_n = 0
    for r in rows:
        name = r["name"]
        if a.only and name not in a.only: continue
        if a.limit and done_n >= a.limit: break
        outj = a.out / f"{name}.club4.json"
        if outj.exists(): done_n += 1; continue
        npy = Path(r["lm"]) if r.get("lm") else r["_rep"] / "landmarks" / f"{name}.npy"
        vid = Path(r["video"])
        if not r.get("phases") or not npy.exists() or not vid.exists(): continue
        lm = np.load(npy).astype(float); lm[~(lm[:, :, 2] >= 0.5), :2] = np.nan
        ad, top, imp = r["phases"]
        end = min(len(lm) - 1, imp + max(2, (imp - ad) // 10))
        frames, _ = ct.read_range(vid, ad, end)
        res = {"name": name, "video": str(vid), "phases": [ad, top, imp], "frames": {}}
        hands0 = ct.hands_at(lm, ad)
        torso = float(np.linalg.norm(ct.mid(lm, ad, ct.LS, ct.RS) - ct.mid(lm, ad, ct.LH, ct.RH)))
        if len(frames) < imp - ad or not np.all(np.isfinite(hands0)) or not np.isfinite(torso) or torso < 20:
            res["status"] = "no frames / landmarks"; outj.write_text(json.dumps(res), encoding="utf-8"); done_n += 1; continue
        ank = lm[ad, [27, 28], :2]
        found = ct.address_shaft(frames[0], hands0, torso, float(np.nanmean(ank[:, 1])), float(np.nanmean(ank[:, 0])))
        if found is None:
            res["status"] = "no address shaft"; outj.write_text(json.dumps(res), encoding="utf-8"); done_n += 1; continue
        head0, _ = found
        pos = [list(hands0 + (head0 - hands0) * t) for t in (0.55, 0.8, 0.97)]
        neg = [list(ct.mid(lm, ad, ct.LH, ct.RH)), list(ct.mid(lm, ad, ct.LK, ct.RK)), list(ct.mid(lm, ad, ct.LS, ct.RS))]
        neg = [p for p in neg if np.all(np.isfinite(p))]
        masks = ct.run_sam(frames, pos + neg, [1] * len(pos) + [0] * len(neg), a.model)
        ok = 0
        for i, m in enumerate(masks):
            f = ad + i; hh = ct.hands_at(lm, f)
            if not np.all(np.isfinite(hh)): res["frames"][f] = None; continue
            pts = four_points(m, hh, torso, abs(f - imp) <= TH)
            res["frames"][f] = pts; ok += pts is not None
        res.update(status="ok", torso=round(torso, 1), tracked=round(ok / max(1, len(masks)), 3))
        # 5 frames for the manual check: address, mid-backswing, top, P6-ish, impact
        picks = [ad, (ad + top) // 2, top, (top + 2 * imp) // 3, imp]
        tiles = []
        for f in picks:
            i = f - ad
            if i >= len(frames): continue
            im = frames[i].copy(); p = res["frames"].get(f)
            if masks[i] is not None: im[masks[i]] = (0.6 * im[masks[i]] + [0, 0, 100]).astype(np.uint8)
            if p:
                for k, col in (("grip_end", (0, 255, 0)), ("hosel", (0, 255, 255)), ("toe", (255, 0, 255)), ("heel", (255, 128, 0))):
                    if p[k]: cv2.circle(im, tuple(map(int, p[k])), 6, col, 2)
            cv2.putText(im, str(f), (8, 28), 0, 0.9, (255, 255, 255), 2)
            tiles.append(cv2.resize(im, (int(im.shape[1] * 360 / im.shape[0]), 360)))
        res["check_frames"] = picks
        cv2.imwrite(str(a.out / f"{name}_check.jpg"), np.hstack(tiles), [cv2.IMWRITE_JPEG_QUALITY, 85])
        tmp = outj.with_suffix(".tmp"); tmp.write_text(json.dumps(res), encoding="utf-8"); os.replace(tmp, outj)
        done_n += 1
        print(name, res["status"], "tracked", res["tracked"], flush=True)


if __name__ == "__main__":
    main()
