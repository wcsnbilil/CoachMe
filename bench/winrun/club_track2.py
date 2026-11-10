"""club_track.py with a sturdier shaft finder and SAM prompting (2026-11-08, Niko clips + pro set).

Changes, all through monkeypatching tools/club/club_track.py:
- address_shaft: radial scan from the hands over a thin-line response (top-hat/black-hat), instead of
  Hough. Picks the direction with the strongest continuous line toward the ground.
- run_sam: crops a box around the golfer and upscales it so the shaft is several px wide; adds
  negative points on the grass on both sides of the shaft; drops masks too big to be a club.
usage: same arguments as club_track.py
"""
import math
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(r"C:\Users\49907\coachme-bench\coachme")
sys.path.insert(0, str(ROOT / "tools" / "club"))
import club_track as ct  # noqa: E402

_orig_address = ct.address_shaft
CANDS = []


def thin_response(img, torso):
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    k = max(5, int(0.06 * torso) | 1)
    ker = cv2.getStructuringElement(cv2.MORPH_RECT, (k, k))
    return cv2.max(cv2.morphologyEx(g, cv2.MORPH_TOPHAT, ker), cv2.morphologyEx(g, cv2.MORPH_BLACKHAT, ker)).astype(float)


def address_shaft(img, hands, torso, ankle_y, ankle_x):
    """Radial scan from the hands: the shaft is a thin line darker (or brighter) than the strips
    0.05 torso either side of it. Grass texture is suppressed by the blur and the side comparison."""
    g = cv2.GaussianBlur(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(float), (0, 0), max(1.0, 0.006 * torso))
    h, w = g.shape
    d = 0.05 * torso
    rs = np.arange(0.25 * torso, 2.6 * torso, 1.0)

    def sample(pts):
        x = np.clip(pts[:, 0], 0, w - 1).astype(int)
        y = np.clip(pts[:, 1], 0, h - 1).astype(int)
        return g[y, x]

    best, score = None, -1.0
    for side in (1, -1):
        for elev in np.arange(20, 83, 0.5):
            u = np.array([side * math.cos(math.radians(elev)), math.sin(math.radians(elev))])
            nv = np.array([-u[1], u[0]])
            pts = hands[None] + rs[:, None] * u[None]
            c = np.abs(0.5 * (sample(pts + d * nv) + sample(pts - d * nv)) - sample(pts))
            on = c > 18
            gap, last = 0, -1
            for i, o in enumerate(on):
                if o:
                    last, gap = i, 0
                elif i > 0.2 * torso:  # the first bit is the hands/glove
                    gap += 1
                    if gap > 0.12 * torso:
                        break
            if last < 0:
                continue
            L = rs[last]
            head = hands + u * L
            if not (0.9 * torso < L < 2.6 * torso):
                continue
            if np.isfinite(ankle_y) and not (ankle_y - 0.6 * torso < head[1] < ankle_y + 0.5 * torso):
                continue
            if np.isfinite(ankle_x) and abs(head[0] - ankle_x) < 0.15 * torso:
                continue
            frac = float(on[:last + 1].mean())
            sc = frac ** 3 * L * float(np.median(c[:last + 1]))
            CANDS.append((round(sc), side, float(elev), round(frac, 2), round(L), round(float(np.median(c[:last + 1])))))
            if sc > score:
                best, score = (head, (hands, head)), sc
    CANDS.sort(reverse=True)
    if best is not None:
        return best
    return _orig_address(img, hands, torso, ankle_y, ankle_x)


def address_shaft_old(img, hands, torso, ankle_y, ankle_x):
    t = thin_response(img, torso)
    h, w = t.shape
    best, score = None, -1.0
    rs = np.arange(0.25 * torso, 2.6 * torso, 1.0)
    for side in (1, -1):
        for elev in np.arange(20, 83, 0.5):
            u = np.array([side * math.cos(math.radians(elev)), math.sin(math.radians(elev))])
            pts = hands[None] + rs[:, None] * u[None]
            inside = (pts[:, 0] >= 0) & (pts[:, 0] < w - 1) & (pts[:, 1] >= 0) & (pts[:, 1] < h - 1)
            if inside.sum() < len(rs) * 0.5:
                continue
            vals = np.zeros(len(rs))
            p = pts[inside].astype(int)
            vals[inside] = t[p[:, 1], p[:, 0]]
            on = vals > max(12.0, np.percentile(t, 90))
            # length of the run of "on" samples starting near the hands (gaps up to 0.1 torso allowed)
            gap, last = 0, -1
            for i, o in enumerate(on):
                if o:
                    last, gap = i, 0
                else:
                    gap += 1
                    if gap > 0.1 * torso:
                        break
            if last < 0:
                continue
            L = rs[last]
            head = hands + u * L
            if not (0.9 * torso < L < 2.6 * torso):
                continue
            if np.isfinite(ankle_y) and not (ankle_y - 0.6 * torso < head[1] < ankle_y + 0.5 * torso):
                continue
            if np.isfinite(ankle_x) and abs(head[0] - ankle_x) < 0.15 * torso:
                continue
            sc = float(vals[:last + 1].mean()) * L
            if sc > score:
                best, score = (head, (hands, head)), sc
    if best is None:
        return _orig_address(img, hands, torso, ankle_y, ankle_x)
    return best


def run_sam(frames, points, labels, model):
    from ultralytics.models.sam import SAM2VideoPredictor
    import tempfile
    pts = np.array(points, float)
    lab = list(labels)
    pos = pts[np.array(lab) == 1]
    neg = pts[np.array(lab) == 0]
    if len(pos) == 3:  # club_track puts them at 0.55/0.8/0.97 of hands->head; the head end can sit on a shadow
        step = (pos[2] - pos[0]) / 0.42
        hands = pos[0] - 0.55 * step
        pos = np.array([hands + step * t for t in (0.35, 0.55, 0.75)])
    H, W = frames[0].shape[:2]
    torso = float(np.linalg.norm(neg[0] - neg[-1])) if len(neg) >= 2 else 0.25 * H
    hip = neg[0]
    # crop: the club reaches ~2.6 torso from the hands, the hands ~1.3 torso from the hips
    x0, x1 = int(max(0, hip[0] - 3.6 * torso)), int(min(W, hip[0] + 3.6 * torso))
    y0, y1 = int(max(0, hip[1] - 4.2 * torso)), int(min(H, hip[1] + 2.6 * torso))
    s = 1024 / max(x1 - x0, y1 - y0)
    cw, ch = int((x1 - x0) * s) // 2 * 2, int((y1 - y0) * s) // 2 * 2
    # grass negatives on both sides of the shaft
    u = pos[-1] - pos[0]
    u /= np.linalg.norm(u) + 1e-9
    nrm = np.array([-u[1], u[0]])
    extra = []
    for p in pos:
        for sgn in (1, -1):
            q = p + sgn * nrm * 0.12 * torso
            if 0 <= q[0] < W and 0 <= q[1] < H:
                extra.append(q)
    allp = np.vstack([pos, neg] + ([np.array(extra)] if extra else []))
    alll = [1] * len(pos) + [0] * (len(neg) + len(extra))
    cp = (allp - [x0, y0]) * s
    tmp = Path(tempfile.mkdtemp()) / "clip.mp4"
    vw = cv2.VideoWriter(str(tmp), cv2.VideoWriter_fourcc(*"mp4v"), 30, (cw, ch))
    for f in frames:
        vw.write(cv2.resize(f[y0:y1, x0:x1], (cw, ch), interpolation=cv2.INTER_CUBIC))
    vw.release()
    pred = SAM2VideoPredictor(overrides=dict(conf=0.25, task="segment", mode="predict", imgsz=1024,
                                             model=model, verbose=False, save=False))
    max_area = 0.5 * (torso * s) ** 2
    masks = []
    for r in pred(source=str(tmp), points=[cp.tolist()], labels=[alll], stream=True):
        if r.masks is None or len(r.masks.data) == 0:
            masks.append(None)
            continue
        m = r.masks.data.any(0).cpu().numpy()
        if m.shape != (ch, cw):
            m = cv2.resize(m.astype(np.uint8), (cw, ch), interpolation=cv2.INTER_NEAREST) > 0
        if m.sum() > max_area or m.sum() < 20:
            masks.append(None)
            continue
        full = np.zeros((H, W), bool)
        full[y0:y1, x0:x1] = cv2.resize(m.astype(np.uint8), (x1 - x0, y1 - y0), interpolation=cv2.INTER_NEAREST) > 0
        masks.append(full)
    return masks


_orig_sam = ct.run_sam


def line_support(img, hands, head, torso):
    """Share of samples along hands->head that look like a thin line (same test as the radial scan)."""
    g = cv2.GaussianBlur(cv2.cvtColor(img, cv2.COLOR_BGR2GRAY).astype(float), (0, 0), max(1.0, 0.006 * torso))
    h, w = g.shape
    v = head - hands
    L = float(np.linalg.norm(v))
    if L < 1:
        return 0.0
    u = v / L
    nv = np.array([-u[1], u[0]])
    rs = np.arange(0.3 * torso, L, 1.0)
    pts = hands[None] + rs[:, None] * u[None]

    def sample(p):
        return g[np.clip(p[:, 1], 0, h - 1).astype(int), np.clip(p[:, 0], 0, w - 1).astype(int)]
    c = np.abs(0.5 * (sample(pts + 0.05 * torso * nv) + sample(pts - 0.05 * torso * nv)) - sample(pts))
    return float((c > 18).mean()) if len(c) else 0.0


def address_combo(img, hands, torso, ankle_y, ankle_x):
    a = _orig_address(img, hands, torso, ankle_y, ankle_x)
    b = address_shaft(img, hands, torso, ankle_y, ankle_x)
    if a is None or b is None:
        return a or b
    sa, sb = line_support(img, hands, a[0], torso), line_support(img, hands, b[0], torso)
    print(f"  address hough support {sa:.2f} radial {sb:.2f}", flush=True)
    return a if sa >= sb - 0.05 else b


def run_sam_combo(frames, points, labels, model):
    m1 = run_sam(frames, points, labels, model)
    n1 = sum(m is not None for m in m1)
    if m1 and m1[0] is not None and n1 >= 0.7 * len(m1):
        return m1
    m2 = _orig_sam(frames, points, labels, model)
    n2 = sum(m is not None for m in m2)
    print(f"  sam cropped {n1}/{len(m1)} full {n2}/{len(m2)}", flush=True)
    return m1 if n1 >= n2 else m2


ct.address_shaft = address_combo
ct.run_sam = run_sam_combo

if __name__ == "__main__":
    ct.main()
