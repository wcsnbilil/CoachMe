"""Target-line prototype for down-the-line (DTL) clips (PM spec 2026-11-10). Python only; no App changes.

Target line source, in order:
  1. an alignment stick (or club) lying on the ground, found on the address frame;
  2. fallback: the camera axis (confidence "low").
Metrics, all as ground-plane angles vs the target line (+ = right of target, i.e. away from a right-handed golfer):
  a) setup: toe line, heel line, hip line, shoulder line (address, median of a few frames);
  b) clubhead direction at impact from frames impact-1 -> impact+1 (reported only when real capture fps >= 120).
Ground plane: pinhole camera, roll 0, horizon row + focal length (defaults estimated; both can be overridden).
usage: python target_line.py VIDEO LANDMARKS.npy --address N [--impact N] [--ball x,y] [--horizon y] [--f px] [--out DIR]
"""
import argparse, json
from pathlib import Path
import cv2, numpy as np

L_SH, R_SH, L_HIP, R_HIP, L_HEEL, R_HEEL, L_TOE, R_TOE, L_WR, R_WR = 11, 12, 23, 24, 29, 30, 31, 32, 15, 16


class Cam:
    def __init__(s, W, H, f, yh):
        s.W, s.H, s.f, s.yh = W, H, f, yh
        s.phi = np.arctan2(H / 2 - yh, f)

    def plane(s, u, v):
        """point on a horizontal plane (any height, up to scale) -> (X right, Z forward)."""
        d = np.array([(u - s.W / 2) / s.f, (v - s.H / 2) / s.f, 1.0])
        c, n = np.cos(s.phi), np.sin(s.phi)
        dw = np.array([d[0], c * d[1] + n * d[2], -n * d[1] + c * d[2]])
        t = 1.0 / abs(dw[1]) if abs(dw[1]) > 1e-6 else 1e6
        return np.array([dw[0] * t, dw[2] * t])

    def heading(s, p, q):
        v = s.plane(*q) - s.plane(*p)
        return float(np.degrees(np.arctan2(v[0], v[1])))


def read_frames(video, want):
    cap = cv2.VideoCapture(str(video)); cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
    out, ts, n = {}, [], 0
    while True:
        ok, im = cap.read()
        if not ok: break
        ts.append(cap.get(cv2.CAP_PROP_POS_MSEC))
        if n in want: out[n] = im
        n += 1
    dt = np.diff([t for t in ts if t > 0])
    fps = 1000.0 / np.median(dt) if len(dt) else 0.0
    return out, fps, n


def horizon_row(im):
    """row where the image stops being sky/trees and becomes grass (first row from top with sustained greenness)."""
    g = im.astype(int)
    gr = (g[..., 1] - (g[..., 0] + g[..., 2]) / 2)[:, im.shape[1] // 4: 3 * im.shape[1] // 4].mean(1)
    k = np.convolve(gr > 6, np.ones(15), "same") >= 15
    rows = np.where(k)[0]
    return float(rows[0]) if len(rows) else None


DBG = []


def find_stick(im, yh, lm, anchor, torso):
    """longest straight thin segment on the ground that is not the club shaft (which passes near the hands)."""
    H, W = im.shape[:2]
    # colour-aware: an orange/yellow stick can have the same brightness as sunlit grass
    lab = cv2.cvtColor(cv2.GaussianBlur(im, (3, 3), 0), cv2.COLOR_BGR2LAB).astype(np.float32)
    e = np.zeros(im.shape[:2], np.uint8)
    for ch in range(3):
        e |= cv2.Canny(lab[..., ch].astype(np.uint8), 30, 90)
    e[: int(yh + 0.08 * H)] = 0
    segs = cv2.HoughLinesP(e, 1, np.pi / 360, 60, minLineLength=int(0.12 * W), maxLineGap=12)
    segs = [] if segs is None else [tuple(s) + (False,) for s in segs.reshape(-1, 4)]
    # second source: thin elongated regions whose colour differs from the local grass (Hough drowns in grass texture).
    # chroma difference, or brighter than the grass; shadows (darker, same hue) are left out on purpose.
    bg = np.dstack([cv2.medianBlur(lab[..., c].astype(np.uint8), 31) for c in range(3)]).astype(np.float32)
    chroma = np.linalg.norm(lab[..., 1:] - bg[..., 1:], axis=2)
    m = ((chroma > 20) | (lab[..., 0] - bg[..., 0] > 35)).astype(np.uint8)
    m[: int(yh + 0.08 * H)] = 0
    m[(lab[..., 0] - bg[..., 0] < -15) & (chroma < 50)] = 0  # shadows: darker, hue close to grass (a red stick is darker too, but far in hue)
    hands0 = (lm[L_WR, :2] + lm[R_WR, :2]) / 2
    # golfer's body (legs, trousers, shoes) from the landmarks, so a trouser crease or shoe edge is not a "stick"
    body = np.zeros((H, W), np.uint8)
    for chain in ((23, 25, 27, 29, 31), (24, 26, 28, 30, 32), (11, 23), (12, 24), (11, 12), (23, 24), (27, 31), (28, 32)):
        for i, j in zip(chain[:-1], chain[1:]):
            if np.isfinite(lm[[i, j], :2]).all():
                cv2.line(body, tuple(map(int, lm[i, :2])), tuple(map(int, lm[j, :2])), 1, max(5, int(0.35 * torso)))
    body = body.astype(bool)
    m[body] = 0
    if anchor is not None:  # cut the address club shaft out so a stick crossing it is not merged with it
        cv2.line(m, tuple(map(int, hands0)), tuple(map(int, anchor)), 0, max(5, int(0.08 * torso)))
    m = cv2.morphologyEx(m, cv2.MORPH_OPEN, np.ones((2, 2), np.uint8))  # a stick 3 m away is only ~4 px wide
    n, lab_cc, st, _ = cv2.connectedComponentsWithStats(m)
    for i in range(1, n):
        if st[i, 4] < 0.08 * W * 2: continue
        ys, xs = np.nonzero(lab_cc[st[i, 1]:st[i, 1] + st[i, 3], st[i, 0]:st[i, 0] + st[i, 2]] == i)
        P = np.column_stack([xs + st[i, 0], ys + st[i, 1]]).astype(float)
        mu = P.mean(0); ev, evec = np.linalg.eigh(np.cov((P - mu).T))
        Lc, Wc = 4 * np.sqrt(max(ev[1], 0)), 4 * np.sqrt(max(ev[0], 1e-6))
        if Lc < 0.08 * W or Lc / Wc < 10: continue
        v = evec[:, 1]; a_, b_ = mu - v * Lc / 2, mu + v * Lc / 2
        segs.append((a_[0], a_[1], b_[0], b_[1], True))
    if not segs: return None, []
    hands = (lm[L_WR, :2] + lm[R_WR, :2]) / 2
    cands = []
    for x1, y1, x2, y2, from_mask in segs:
        p, q = np.array([x1, y1], float), np.array([x2, y2], float)
        if q[1] > p[1]: p, q = q, p  # p = near end (lower in image)
        d = q - p; L = np.linalg.norm(d)
        if L < 1: continue
        if anchor is not None:  # the club shaft at address runs hands -> clubhead (next to the ball): reject overlaps
            sd = anchor - hands; sl = np.linalg.norm(sd)

            def dseg(x):
                t = np.clip(np.dot(x - hands, sd) / sl ** 2, 0, 1)
                return np.linalg.norm(hands + t * sd - x)
            if dseg(p) < 0.15 * torso and dseg(q) < 0.15 * torso: DBG.append(('shaft', p, q)); continue
        # the address shaft starts at the hands: any line whose extension runs through the hands is the shaft
        # (wrist landmarks sit a little off the grip, hence the loose 0.25 torso)
        if abs(np.cross(d, hands - p)) / L < 0.25 * torso and np.linalg.norm(q - hands) < 1.2 * torso:
            DBG.append(('shaft_line', p, q)); continue
        if body is not None and body[int(np.clip((p[1] + q[1]) / 2, 0, H - 1)), int(np.clip((p[0] + q[0]) / 2, 0, W - 1))]:
            DBG.append(('body', p, q)); continue
        if abs(d[1]) < 0.15 * L: DBG.append(('flat', p, q)); continue  # nearly horizontal in image: not a target-direction line in DTL
        # must be near the golfer's feet / ball area (sticks are laid by the feet or just past the ball)
        if anchor is not None:
            t = np.clip(np.dot(anchor - p, d) / L ** 2, 0, 1)
            if np.linalg.norm(p + t * d - anchor) > 1.2 * torso: DBG.append(('far', p, q)); continue
        # thin-object check: centre differs from both sides (a shadow edge only differs on one side)
        # averaged along the segment so grass texture cancels; a real stick keeps a band of steady contrast
        nrm = np.array([-d[1], d[0]]) / L; w = max(3.0, 0.03 * torso); thin = from_mask
        ss = [p + s * d for s in np.linspace(0.05, 0.95, 40)]
        ss = [c for c in ss if 4 * w < c[0] < W - 4 * w and 4 * w < c[1] < H - 4 * w]
        if len(ss) < 10: continue
        def samp(off):
            return np.array([lab[int(c[1] + off * nrm[1]), int(c[0] + off * nrm[0])] for c in ss])
        for o in np.linspace(-1.5 * w, 1.5 * w, 7):  # Hough may sit on either edge of the stick
            vc, v1, v2 = samp(o), samp(o + 2.5 * w), samp(o - 2.5 * w)
            d1, d2 = np.linalg.norm(vc - v1, axis=1), np.linalg.norm(vc - v2, axis=1)
            # both sides alike (grass), centre different, and the centre colour steady along the stick
            # per sample; tolerant of the stick crossing a shadow for part of its length
            ok = (d1 > 25) & (d2 > 25) & (np.linalg.norm(v1 - v2, axis=1) < 0.6 * np.minimum(d1, d2))
            if ok.mean() > 0.6:
                thin = True; break
        if not thin: DBG.append(('thick', p, q)); continue
        # a stick lies on grass: both flanks should be green (OpenCV Lab: a < 128 means green-ish)
        fl = np.vstack([samp(3 * w), samp(-3 * w)])
        if np.median(fl[:, 1]) > 124: DBG.append(('not_on_grass', p, q)); continue
        cands.append((L, p.tolist(), q.tolist()))
    cands.sort(reverse=True)
    # merge collinear duplicates (both edges of a stick): keep the longest
    return (cands[0] if cands else None), cands[:8]


def blobs(im, dark):
    hsv = cv2.cvtColor(im, cv2.COLOR_BGR2HSV)
    m = (hsv[..., 2] < 70) if dark else ((hsv[..., 2] > 200) & (hsv[..., 1] < 60))
    k, _, st, cen = cv2.connectedComponentsWithStats(m.astype(np.uint8))
    return [(cen[i], st[i, 4]) for i in range(1, k)]


def find_ball(im, late, lm, torso):
    """white blob that is present at address and gone in a late frame (the ball was hit), near the toes' row,
    on the far side of the hands from the hips. Static camera assumed. Override with --ball."""
    hands = (lm[L_WR, :2] + lm[R_WR, :2]) / 2
    hips = (lm[L_HIP, :2] + lm[R_HIP, :2]) / 2
    toes_y = (lm[L_TOE, 1] + lm[R_TOE, 1]) / 2
    side = np.sign(hands[0] - hips[0]) or 1
    hsv = cv2.cvtColor(im, cv2.COLOR_BGR2HSV); hl = cv2.cvtColor(late, cv2.COLOR_BGR2HSV)
    wa = (hsv[..., 2] > 200) & (hsv[..., 1] < 45)  # sunlit grass reaches S~60-70, a ball stays < 40
    wl = cv2.dilate(((hl[..., 2] > 200) & (hl[..., 1] < 45)).astype(np.uint8), np.ones((5, 5), np.uint8)) > 0
    m = cv2.morphologyEx((wa & ~wl).astype(np.uint8), cv2.MORPH_OPEN, np.ones((3, 3), np.uint8))
    k, _, st, cen = cv2.connectedComponentsWithStats(m)
    best = None
    for i in range(1, k):
        x, y, w, h, a = st[i]; c = cen[i]
        if not (0.001 * torso ** 2 < a < 0.04 * torso ** 2): continue
        if not (0.6 < w / max(h, 1) < 1.6 and a / (w * h) > 0.5): continue
        if abs(c[1] - toes_y) > 0.5 * torso or (c[0] - hands[0]) * side < 0: continue
        s = abs(c[1] - toes_y) + 0.3 * abs(c[0] - hands[0])
        if best is None or s < best[0]: best = (s, c)
    return None if best is None else best[1]


def impact_frame(frames, ball, r):
    """first frame from which the ball is gone for good (the takeaway can hide it briefly, so require it to stay gone)."""
    x, y = int(ball[0]), int(ball[1])
    ks = sorted(frames)

    def white(k):
        p = cv2.cvtColor(frames[k][y - r:y + r, x - r:x + r], cv2.COLOR_BGR2HSV)
        return ((p[..., 2] > 200) & (p[..., 1] < 45)).mean()
    w = np.array([white(k) for k in ks])
    vis = w > 0.35 * w[0]
    if vis[-1] or not vis.any(): return None
    last_vis = int(np.where(vis)[0].max())
    return ks[last_vis + 1]


def head_track(frames, ball, imp, torso):
    """dark-blob clubhead near the ball for imp-2..imp+2, chained by nearest neighbour from the ball spot."""
    r = int(0.5 * torso)

    def near(k, seed):
        im = frames[k]; H, W = im.shape[:2]
        x0, y0 = max(0, int(seed[0]) - r), max(0, int(seed[1]) - r)
        roi = cv2.cvtColor(im[y0:int(seed[1]) + r, x0:int(seed[0]) + r], cv2.COLOR_BGR2HSV)
        n, _, st, cen = cv2.connectedComponentsWithStats((roi[..., 2] < 70).astype(np.uint8))
        best = None
        for i in range(1, n):
            a = st[i, 4]
            if a < 0.012 * torso ** 2: continue
            c = cen[i] + (x0, y0)
            s = np.linalg.norm(c - seed) - 0.01 * a
            if best is None or s < best[0]: best = (s, c)
        return None if best is None else best[1]
    pts = {}
    prev = np.array(ball, float)
    for k in (imp, imp + 1, imp + 2):
        c = near(k, prev)
        if c is None: break
        pts[k] = c; prev = c
    prev = pts.get(imp, np.array(ball, float))
    for k in (imp - 1, imp - 2):
        c = near(k, prev)
        if c is None: break
        pts[k] = c; prev = c
    return pts


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path); ap.add_argument("landmarks", type=Path)
    ap.add_argument("--address", type=int, required=True); ap.add_argument("--impact", type=int)
    ap.add_argument("--search-to", type=int, help="last frame to search for impact (default address+fps*3)")
    ap.add_argument("--ball"); ap.add_argument("--horizon", type=float); ap.add_argument("--f", type=float)
    ap.add_argument("--no-stick", action="store_true"); ap.add_argument("--out", type=Path, default=Path("target_out"))
    a = ap.parse_args()
    lm_all = np.load(a.landmarks)
    adr = a.address
    lm = np.median(lm_all[adr:adr + 5], axis=0)
    torso = float(np.linalg.norm((lm[L_SH, :2] + lm[R_SH, :2]) / 2 - (lm[L_HIP, :2] + lm[R_HIP, :2]) / 2))
    cap = cv2.VideoCapture(str(a.video)); n_total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT)); cap.release()
    hi = a.search_to or min(n_total - 1, adr + 400)
    frames, fps, n = read_frames(a.video, set(range(adr, hi + 3)))
    im = frames[adr]; H, W = im.shape[:2]
    f = a.f or 0.72 * max(W, H)  # iPhone 1x main camera, 16:9 video ~ 69 deg across the long side
    yh = a.horizon if a.horizon is not None else horizon_row(im)
    notes = []
    if yh is None:
        yh = H / 2 - f * np.tan(np.radians(8)); notes.append("horizon not found; assumed 8 deg down-pitch")
    cam = Cam(W, H, f, yh)
    res = {"video": str(a.video), "fps_capture": round(fps, 1), "frames": n, "f_px": round(f), "horizon_row": round(yh), "notes": notes}

    ball = np.array([float(v) for v in a.ball.split(",")]) if a.ball else find_ball(im, frames[max(frames)], lm, torso)
    anchor = ball if ball is not None else (lm[L_TOE, :2] + lm[R_TOE, :2]) / 2
    stick, cands = (None, []) if a.no_stick else find_stick(im, yh, lm, anchor, torso)
    if stick and abs(cam.heading(stick[1], stick[2])) > 30:  # a DTL camera is never that far off the target line
        res["rejected_stick"] = {"segment": [stick[1], stick[2]], "heading": round(cam.heading(stick[1], stick[2]), 1)}
        stick = None
    if stick:
        L, p, q = stick
        tgt = cam.heading(p, q)
        res["target"] = {"source": "stick", "confidence": "medium", "camera_axis_offset_deg": round(tgt, 1), "segment": [p, q]}
    else:
        tgt = 0.0
        res["target"] = {"source": "camera_axis", "confidence": "low",
                         "why": "no alignment stick found; assumes the camera points at the target"}
    res["stick_candidates"] = [[round(c[0]), c[1], c[2]] for c in cands]

    def rel(p, q):
        return round(cam.heading(p, q) - tgt, 1)
    # trail (near) -> lead (far): right-handed DTL, the trail side is the right side
    res["setup"] = {"toe_line": rel(lm[R_TOE, :2], lm[L_TOE, :2]), "heel_line": rel(lm[R_HEEL, :2], lm[L_HEEL, :2]),
                    "hip_line": rel(lm[R_HIP, :2], lm[L_HIP, :2]), "shoulder_line": rel(lm[R_SH, :2], lm[L_SH, :2]),
                    "visibility_far_side": [round(float(lm[i, 2]), 2) for i in (L_TOE, L_HEEL, L_HIP, L_SH)],
                    "sign": "+ = aimed right of target (closed for RH), - = left (open)"}

    res["ball"] = None if ball is None else [round(float(v), 1) for v in ball]
    imp = a.impact
    if imp is None and ball is not None:
        hit = impact_frame({k: v for k, v in frames.items() if k <= hi}, ball, max(6, int(0.04 * torso)))
        imp = None if hit is None else hit - 1  # last frame with the ball still on the tee
    res["impact"] = imp
    if fps < 119:
        res["club_direction"] = {"status": "not measurable", "why": f"capture fps {fps:.0f} < 120"}
    elif imp is None or ball is None:
        res["club_direction"] = {"status": "not measured", "why": "ball or impact not found"}
    else:
        pts = head_track(frames, ball, imp, torso)
        res["head_pts"] = {k: [round(float(c[0]), 1), round(float(c[1]), 1)] for k, c in sorted(pts.items())}
        if imp - 1 in pts and imp + 1 in pts:
            res["club_direction"] = {"status": "ok", "deg": rel(pts[imp - 1], pts[imp + 1]), "frames": [imp - 1, imp + 1]}
        else:
            res["club_direction"] = {"status": "not measured", "why": "clubhead not tracked on both sides of impact"}

    a.out.mkdir(parents=True, exist_ok=True)
    o = im.copy()
    if stick: cv2.line(o, tuple(map(int, stick[1])), tuple(map(int, stick[2])), (0, 165, 255), 4)
    cv2.line(o, (0, int(yh)), (W, int(yh)), (255, 255, 0), 1)
    for i, j, col in ((R_TOE, L_TOE, (0, 0, 255)), (R_SH, L_SH, (255, 0, 255)), (R_HIP, L_HIP, (255, 128, 0))):
        cv2.line(o, tuple(map(int, lm[i, :2])), tuple(map(int, lm[j, :2])), col, 3)
    if ball is not None: cv2.circle(o, tuple(map(int, ball)), 14, (255, 255, 255), 2)
    for k, c in res.get("head_pts", {}).items(): cv2.circle(o, tuple(map(int, c)), 8, (0, 255, 0), 2)
    stem = a.video.stem
    cv2.imwrite(str(a.out / f"{stem}_target.jpg"), o)
    (a.out / f"{stem}_target.json").write_text(json.dumps(res, indent=1, default=float), encoding="utf-8")
    print(json.dumps({k: res[k] for k in ("fps_capture", "horizon_row", "target", "setup", "ball", "impact", "club_direction")}, default=float))


if __name__ == "__main__":
    main()
