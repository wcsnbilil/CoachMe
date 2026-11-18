"""Prototype of a display-only world-landmark smoother (same local-linear kernel as the app's
PoseDisplaySmoother, 3D, metres) on the 160 pro swings. usage: python w3d_ll.py <w3d dir> [sigma_s_m]"""
import json, sys, math, collections
from pathlib import Path
import numpy as np
d = Path(sys.argv[1]); SS = float(sys.argv[2]) if len(sys.argv) > 2 else 0.08; ST = 0.045; WIN = 0.10
def ll(W, ts, vis):
    out = W.copy()
    for i in range(len(W)):
        ks = [k for k in range(len(W)) if abs(ts[k] - ts[i]) <= WIN]
        for j in range(W.shape[1]):
            if not (vis[i, j] >= 0.5): continue
            w0 = w1 = w2 = 0.0; p0 = np.zeros(3); p1 = np.zeros(3)
            for k in ks:
                if not (vis[k, j] >= 0.5): continue
                dt = ts[k] - ts[i]; dl = W[k, j] - W[i, j]
                w = math.exp(-0.5 * (dt * dt / ST ** 2 + float(dl @ dl) / SS ** 2))
                w0 += w; w1 += w * dt; w2 += w * dt * dt; p0 += w * W[k, j]; p1 += w * dt * W[k, j]
            det = w0 * w2 - w1 * w1
            if det > 1e-10: out[i, j] = (p0 * w2 - p1 * w1) / det
    return out
def yaw(W, f, a, b):
    v = W[f, b] - W[f, a]; return math.degrees(math.atan2(v[2], v[0]))
def wrap(x): return (x + 180) % 360 - 180
def jit(W, a, i, vis):
    h = (W[a:i + 1, 15] + W[a:i + 1, 16]) / 2; return float(np.nanmedian(np.linalg.norm(np.diff(h, 2, axis=0), axis=1)))
def dirjit(W, a, i):  # lead forearm direction change per frame (deg), what the fixed-length avatar shows
    v = W[a:i + 1, 15] - W[a:i + 1, 13]; v = v / np.linalg.norm(v, axis=1, keepdims=True)
    c = np.clip(np.sum(v[1:] * v[:-1], 1), -1, 1); ang = np.degrees(np.arccos(c))
    return float(np.nanmedian(np.abs(np.diff(ang))))
rows = []
for js in sorted(d.glob("*.json")):
    if js.name.startswith("w3d"): continue
    m = json.loads(js.read_text(encoding="utf-8")); a, t, i = m["phases"]
    R = np.load(js.with_suffix(".npy"))
    if i >= len(R): continue
    vis = R[:, :, 3]; W = R[:, :, :3].copy()
    if not np.isfinite(W[[a, t]][:, [11, 12]]).all(): continue
    ts = np.arange(len(W)) / (m.get("fps") or 30)
    # slow-mo clips: timestamps are video time, so the smoother sees them as slow, like the app does
    S = ll(W, ts, vis)
    r = {"view": m["view"], "src": m.get("src", "golfdb"), "slow": m.get("slow"), "yt": m.get("youtube_id"), "player": m.get("player")}
    for tag, X in (("raw", W), ("ll", S)):
        r[f"sh_{tag}"] = abs(wrap(yaw(X, t, 11, 12) - yaw(X, a, 11, 12)))
        r[f"jit_{tag}"] = jit(X, a, i, vis); r[f"dj_{tag}"] = dirjit(X, a, i)
        # fidelity: hand position at impact vs raw (lag/overshoot), metres
    r["impact_shift"] = float(np.linalg.norm(((S[i, 15] + S[i, 16]) - (W[i, 15] + W[i, 16])) / 2))
    rows.append(r)
grp = collections.defaultdict(list)
for r in rows: grp[(r["src"], r["view"])].append(r)
for k, rs in sorted(grp.items()):
    f = lambda key: np.nanmedian([r[key] for r in rs])
    print(f"{k} n={len(rs)}: hand jitter {f('jit_raw')*1000:.1f}->{f('jit_ll')*1000:.1f} mm; forearm direction jitter {f('dj_raw'):.1f}->{f('dj_ll'):.1f} deg/frame; impact hand shift p50 {f('impact_shift')*100:.1f} cm p90 {np.nanpercentile([r['impact_shift'] for r in rs],90)*100:.1f} cm; shoulder turn p50 {f('sh_raw'):.0f}->{f('sh_ll'):.0f}")
pairs = collections.defaultdict(dict)
for r in rows:
    if r["slow"] is not None: pairs[(r["yt"], r["player"], r["view"])][r["slow"]] = r
for tag in ("raw", "ll"):
    dd = [abs(g[0][f"sh_{tag}"] - g[1][f"sh_{tag}"]) for g in pairs.values() if 0 in g and 1 in g]
    dd = [x for x in dd if np.isfinite(x)]
    print(f"RT vs slow |shoulder diff| {tag}: p50 {np.median(dd):.1f} p90 {np.percentile(dd,90):.1f} n {len(dd)}")
