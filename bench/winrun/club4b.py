"""club4 v2 (computer B, 2026-11-12): 4 club points per frame, with prompts and mask clean-up aimed at the
"SAM follows the trouser leg" failure of club4.py. club4.py itself is unchanged.

Differences from club4.py:
- hands: wrists + index knuckles at visibility >= 0.3, gaps interpolated (club4 dropped every frame under 0.5).
- prompts: positives on the address shaft only where they are at least LEG_CLEAR torso away from both legs;
  negatives along both legs (hip, mid-thigh, knee, mid-shin, ankle), on the trunk, and on the grass either side of the shaft.
- address check: the frame-0 mask must be a thin line within ADDR_DEG of the address shaft; if not, one retry with
  a second prompt set (positives nearer the clubhead, no grass negatives).
- per-frame clean-up: keep only the thin part of the mask (mask minus its opening with a disc ~ shaft-too-wide),
  plus a small head blob attached to it; then only components that start near the hands. A leg that leaks into the
  mask is wider than the disc and is removed instead of spoiling the whole frame.
- gate (plan B, 2026-11-12): a swing is kept only when its address mask is a thin line within ADDR_DEG of the address shaft;
  otherwise it is skipped and no points are written. A frame whose mask does not start near the hands is invalid.
- batch use: --keep keep.jsonl runs view=dtl clips first, --progress writes a small json after every swing, swings over
  --max-frames are skipped (frames are held in memory), finished swings are skipped on restart.
usage: python club4b.py REPORT_DIR [...] --out DIR [--only name ...] [--names-from DIR] [--limit N] [--keep keep.jsonl] [--progress FILE]"""
import argparse, json, math, os, sys, tempfile
from pathlib import Path
import cv2, numpy as np

sys.path.insert(0, str(Path(__file__).parent))
import club_track2  # noqa: F401  (patches club_track.address_shaft with the Hough / radial combo)
import club_track as ct
from club4 import four_points, TH

LEG_CLEAR, ADDR_DEG = 0.14, 18.0
LEGS = [(23, 25), (25, 27), (24, 26), (26, 28)]  # hip-knee, knee-ankle, both sides


def hands_series(lm):
    x = lm[:, [15, 16, 19, 20], :].copy()
    x[~(x[:, :, 2] >= 0.3), :2] = np.nan
    with np.errstate(all="ignore"):
        h = np.nanmean(x[:, :, :2], 1)
    for c in range(2):
        ok = np.isfinite(h[:, c])
        if ok.sum() >= 2:
            h[~ok, c] = np.interp(np.flatnonzero(~ok), np.flatnonzero(ok), h[ok, c])
    return h


def seg_dist(p, a, b):
    ab = b - a; t = np.clip(np.dot(p - a, ab) / (np.dot(ab, ab) + 1e-9), 0, 1)
    return float(np.linalg.norm(p - (a + t * ab)))


def prompts(lm, ad, hands0, head0, torso, shape, variant):
    H, W = shape
    J = lambda i: lm[ad, i, :2]
    legs = [(J(a), J(b)) for a, b in LEGS if np.all(np.isfinite(J(a))) and np.all(np.isfinite(J(b)))]
    ts = {0: (0.6, 0.75, 0.9), 1: (0.35, 0.5, 0.65, 0.8), 2: (0.88, 0.95)}[variant]
    pos = [hands0 + (head0 - hands0) * t for t in ts]
    clear = [p for p in pos if all(seg_dist(p, a, b) >= LEG_CLEAR * torso for a, b in legs)]
    pos = clear if len(clear) >= 2 else sorted(pos, key=lambda p: -min([seg_dist(p, a, b) for a, b in legs] or [1e9]))[:2]
    neg = []
    for a, b in legs:
        neg += [a + (b - a) * t for t in (0.0, 0.5, 1.0)]
    for a, b in ((11, 12), (23, 24)):
        m = ct.mid(lm, ad, a, b)
        if np.all(np.isfinite(m)): neg.append(m)
    u = (head0 - hands0) / (np.linalg.norm(head0 - hands0) + 1e-9); nrm = np.array([-u[1], u[0]])
    if variant == 1:
        for p in pos:
            neg += [p + s * nrm * 0.12 * torso for s in (1, -1)]
    # a negative must not sit on the shaft itself, nor outside the image
    neg = [q for q in neg if 0 <= q[0] < W and 0 <= q[1] < H and seg_dist(q, hands0, head0) >= 0.07 * torso]
    return np.array(pos), np.array(neg)


def run_sam(frames, pos, neg, hip, torso, model):
    """Cropped, upscaled SAM 2 video run (as club_track2.run_sam) with the given prompt points. Raw masks back."""
    from ultralytics.models.sam import SAM2VideoPredictor
    H, W = frames[0].shape[:2]
    x0, x1 = int(max(0, hip[0] - 3.6 * torso)), int(min(W, hip[0] + 3.6 * torso))
    y0, y1 = int(max(0, hip[1] - 4.2 * torso)), int(min(H, hip[1] + 2.6 * torso))
    s = 1024 / max(x1 - x0, y1 - y0)
    cw, ch = int((x1 - x0) * s) // 2 * 2, int((y1 - y0) * s) // 2 * 2
    allp = np.vstack([pos, neg]) if len(neg) else pos
    lab = [1] * len(pos) + [0] * len(neg)
    cp = (allp - [x0, y0]) * s
    d = Path(tempfile.mkdtemp()); tmp = d / "clip.mp4"
    vw = cv2.VideoWriter(str(tmp), cv2.VideoWriter_fourcc(*"mp4v"), 30, (cw, ch))
    for f in frames:
        vw.write(cv2.resize(f[y0:y1, x0:x1], (cw, ch), interpolation=cv2.INTER_CUBIC))
    vw.release()
    pred = SAM2VideoPredictor(overrides=dict(conf=0.25, task="segment", mode="predict", imgsz=1024, model=model, verbose=False, save=False))
    masks = []
    for r in pred(source=str(tmp), points=[cp.tolist()], labels=[lab], stream=True):
        if r.masks is None or len(r.masks.data) == 0:
            masks.append(None); continue
        m = r.masks.data.any(0).cpu().numpy()
        if m.shape != (ch, cw):
            m = cv2.resize(m.astype(np.uint8), (cw, ch), interpolation=cv2.INTER_NEAREST) > 0
        full = np.zeros((H, W), bool)
        full[y0:y1, x0:x1] = cv2.resize(m.astype(np.uint8), (x1 - x0, y1 - y0), interpolation=cv2.INTER_NEAREST) > 0
        masks.append(full if full.sum() >= 20 else None)
    try:
        tmp.unlink(); d.rmdir()
    except OSError:
        pass
    return masks


def clean(m, hands, torso):
    """Thin part of the mask (+ a small head blob touching it), restricted to components that begin near the hands."""
    if m is None or not np.all(np.isfinite(hands)): return None
    ys, xs = np.nonzero(m)
    if len(xs) < 20: return None
    x0, x1, y0, y1 = max(0, xs.min() - 4), xs.max() + 5, max(0, ys.min() - 4), ys.max() + 5
    sub = m[y0:y1, x0:x1].astype(np.uint8)
    k = max(11, int(0.14 * torso) | 1)  # wider than a (SAM-fattened) shaft, narrower than a calf
    ker = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (k, k))
    opened = cv2.morphologyEx(sub, cv2.MORPH_OPEN, ker)
    thin = (sub > 0) & (opened == 0)
    out = thin.copy()
    n, lab, st, _ = cv2.connectedComponentsWithStats(opened, 8)
    if thin.any():
        near = cv2.dilate(thin.astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
        for i in range(1, n):  # fat pieces: keep only a small one that touches the thin part = the clubhead
            if st[i, cv2.CC_STAT_AREA] <= (0.3 * torso) ** 2 and (near & (lab == i)).any():
                out |= lab == i
    n, lab, st, _ = cv2.connectedComponentsWithStats(out.astype(np.uint8), 8)
    keep = np.zeros_like(out)
    hx, hy = hands[0] - x0, hands[1] - y0
    for i in range(1, n):
        if st[i, cv2.CC_STAT_AREA] < 25: continue
        py, px = np.nonzero(lab == i)
        if np.hypot(px - hx, py - hy).min() <= 0.45 * torso:
            keep |= lab == i
    if keep.sum() < 30: return None
    full = np.zeros_like(m); full[y0:y1, x0:x1] = keep
    return full


def axis_deg(m):
    ys, xs = np.nonzero(m)
    P = np.column_stack([xs, ys]).astype(float); P -= P.mean(0)
    ev, evec = np.linalg.eigh(np.cov(P.T)); v = evec[:, 1]
    return math.degrees(math.atan2(v[1], v[0])), float(np.sqrt(max(ev[1], 0) / max(ev[0], 1e-9)))


def near_hands(m, hands, torso):
    ys, xs = np.nonzero(m)
    return len(xs) > 0 and float(np.hypot(xs - hands[0], ys - hands[1]).min()) <= 0.45 * torso


def process(r, a, outj):
    """One swing. Gate (plan B): the address mask must be a thin line within ADDR_DEG of the address shaft,
    else the whole swing is skipped (no points written). Frames whose mask does not start near the hands are invalid."""
    name = r["name"]
    res = {"name": name, "video": r["video"], "phases": r["phases"], "frames": {}, "passed": False}

    def finish(status):
        res["status"] = status
        tmp = outj.with_suffix(".tmp"); tmp.write_text(json.dumps(res), encoding="utf-8"); os.replace(tmp, outj)
        print(name, status, "tracked", res.get("tracked"), flush=True)
        return res
    lm = np.load(r["lm"]).astype(float)
    ad, top, imp = r["phases"]
    end = min(len(lm) - 1, imp + max(2, (imp - ad) // 10))
    if end - ad + 1 > a.max_frames:  # 1080p frames are held in memory: ~6 MB each
        return finish(f"skipped: {end - ad + 1} frames > {a.max_frames}")
    frames, _ = ct.read_range(Path(r["video"]), ad, end)
    hs = hands_series(lm)
    body = lm.copy(); body[~(body[:, :, 2] >= 0.3), :2] = np.nan
    torso = float(np.linalg.norm(ct.mid(body, ad, ct.LS, ct.RS) - ct.mid(body, ad, ct.LH, ct.RH)))
    if len(frames) < imp - ad: return finish(f"skipped: video gave {len(frames)} frames, need {imp - ad}")
    if not np.all(np.isfinite(hs[ad])) or not np.isfinite(torso) or torso < 20: return finish("skipped: no hands / torso at address")
    ank = body[ad, [27, 28], :2]
    with np.errstate(all="ignore"):
        ay, ax = float(np.nanmean(ank[:, 1])), float(np.nanmean(ank[:, 0]))
    found = ct.address_shaft(frames[0], hs[ad], torso, ay, ax)
    if found is None: return finish("skipped: no address shaft")
    head0 = np.asarray(found[0], float); hands0 = hs[ad]
    shaft_deg = math.degrees(math.atan2(head0[1] - hands0[1], head0[0] - hands0[0]))
    hip = ct.mid(body, ad, ct.LH, ct.RH)
    chosen, offs = None, []
    for variant in (0, 1, 2):
        pos, neg = prompts(body, ad, hands0, head0, torso, frames[0].shape[:2], variant)
        raw = run_sam(frames, pos, neg, hip, torso, a.model)
        cl = []
        for i, m in enumerate(raw):
            h = hs[ad + i]
            c = clean(m, h, torso)
            # the thin-part filter found nothing but the raw mask is itself a thin line that starts at the hands: keep it
            if c is None and m is not None and np.all(np.isfinite(h)) and near_hands(m, h, torso) \
                    and four_points(m, h, torso, False) is not None:
                c = m
            cl.append(c)
        m0 = next((c for c in cl[:3] if c is not None), None)  # address mask: first of the first three frames
        off, addr_ok = None, False
        if m0 is not None:
            deg, elong = axis_deg(m0)
            off = min(abs((deg - shaft_deg + 90) % 180 - 90), 90)
            addr_ok = off <= ADDR_DEG and elong >= 4
        offs.append(None if off is None else round(off, 1))
        n_ok = sum(m is not None for m in cl)
        print(f"  {name} prompts v{variant}: pos {len(pos)} neg {len(neg)} raw {sum(m is not None for m in raw)}/{len(raw)} "
              f"clean {n_ok}/{len(cl)} address off-line {offs[-1]} ok={addr_ok}", flush=True)
        if addr_ok and (chosen is None or n_ok > chosen[0]):
            chosen = (n_ok, variant, pos, neg, raw, cl, off)
        if addr_ok and n_ok >= 0.6 * len(cl): break
    res.update(torso=round(torso, 1), address_off_deg_by_variant=offs)
    if chosen is None:
        return finish("skipped: address mask not a thin line on the address shaft")
    n_ok, variant, pos, neg, raw, cl, off = chosen
    ok = 0
    for i, m in enumerate(cl):
        f = ad + i
        pts = four_points(m, hs[f], torso, abs(f - imp) <= TH) if m is not None else None
        res["frames"][f] = pts; ok += pts is not None
    res.update(tracked=round(ok / max(1, len(cl)), 3), prompt_variant=variant, address_off_deg=round(off, 1), passed=True)
    picks = [ad, (ad + top) // 2, top, (top + 2 * imp) // 3, imp]
    tiles = []
    for f in picks:
        i = f - ad
        if i >= len(frames): continue
        im = frames[i].copy(); p = res["frames"].get(f)
        if raw[i] is not None: im[raw[i]] = (0.75 * im[raw[i]] + [60, 0, 0]).astype(np.uint8)       # raw SAM mask: blue tint
        if cl[i] is not None: im[cl[i]] = (0.5 * im[cl[i]] + [0, 0, 127]).astype(np.uint8)         # cleaned: red
        if i == 0:
            for q in pos: cv2.circle(im, tuple(map(int, q)), 5, (0, 255, 0), -1)
            for q in neg: cv2.circle(im, tuple(map(int, q)), 5, (0, 0, 0), -1)
            cv2.line(im, tuple(map(int, hands0)), tuple(map(int, head0)), (255, 255, 255), 1)
        if p:
            for k, col in (("grip_end", (0, 255, 0)), ("hosel", (0, 255, 255)), ("toe", (255, 0, 255)), ("heel", (255, 128, 0))):
                if p[k]: cv2.circle(im, tuple(map(int, p[k])), 7, col, 2)
        cv2.putText(im, str(f), (8, 28), 0, 0.9, (255, 255, 255), 2)
        tiles.append(cv2.resize(im, (int(im.shape[1] * 360 / im.shape[0]), 360)))
    res["check_frames"] = picks
    cv2.imwrite(str(a.out / f"{name}_check.jpg"), np.hstack(tiles), [cv2.IMWRITE_JPEG_QUALITY, 85])
    return finish("ok")


def main():
    import time
    ap = argparse.ArgumentParser()
    ap.add_argument("report", type=Path, nargs="+"); ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--only", nargs="*"); ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--names-from", type=Path, help="run exactly the swings that have a <name>.club4.json in this folder")
    ap.add_argument("--max-frames", type=int, default=400, help="skip swings longer than this (address..impact + follow-through)")
    ap.add_argument("--keep", type=Path, help="hd_collect keep.jsonl: swings from clips marked view=dtl run first")
    ap.add_argument("--progress", type=Path, help='write {"stage","done","total","updated"} here after every swing')
    ap.add_argument("--model", default=str(Path(r"C:\Users\k8881\coachme-bench\coachme\sam2_b.pt")))
    a = ap.parse_args(); a.out.mkdir(parents=True, exist_ok=True)
    only = set(a.only or [])
    if a.names_from:
        only |= {p.name[:-len(".club4.json")] for p in a.names_from.glob("*.club4.json")}
    rows = []
    for rep in a.report:
        if (rep / "results.json").exists():
            rows += json.loads((rep / "results.json").read_text(encoding="utf-8"))
    rows = [r for r in rows if not only or r["name"] in only]
    if a.keep and a.keep.exists():
        view = {}
        for l in a.keep.open(encoding="utf-8"):
            k = json.loads(l); view[k["id"]] = k.get("view")
        rows.sort(key=lambda r: view.get(Path(r["video"]).stem) != "dtl")  # stable: dtl first, file order otherwise
    if a.limit: rows = rows[:a.limit]
    done = passed = 0
    for r in rows:
        outj = a.out / f"{r['name']}.club4.json"
        if outj.exists():
            try:
                passed += bool(json.loads(outj.read_text(encoding="utf-8")).get("passed"))
            except ValueError:
                pass
        else:
            try:
                passed += bool(process(r, a, outj).get("passed"))
            except Exception as e:  # one bad swing must not stop the batch
                outj.write_text(json.dumps({"name": r["name"], "video": r["video"], "phases": r["phases"], "frames": {},
                                            "passed": False, "status": f"error: {e!r}"}), encoding="utf-8")
                print(r["name"], "error", repr(e), flush=True)
        done += 1
        if a.progress:
            a.progress.parent.mkdir(parents=True, exist_ok=True)
            a.progress.write_text(json.dumps({"stage": "球杆4点", "key": "club4b", "done": done, "total": len(rows), "passed": passed,
                                              "updated": time.strftime("%Y-%m-%dT%H:%M:%S")}, ensure_ascii=False), encoding="utf-8")
    print("done", done, "of", len(rows), "passed", passed, flush=True)


if __name__ == "__main__":
    main()
