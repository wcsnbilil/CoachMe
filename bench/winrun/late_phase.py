"""P6 -> impact body metrics from pose only (no club). Signed so + = toward the ball, in torso lengths.
hands_out: hands x at impact minus hands x at address.  hip_in: hip midpoint x at impact minus address
(early extension = hips toward the ball).  spine_up: spine tilt from vertical at address minus at impact,
degrees (+ = stood up).  head_in: nose x at impact minus address.
usage: late_phase.py out.json  (GolfDB 400 from win_v4_400 + Niko clips)"""
import json, math, sys
from pathlib import Path
import numpy as np
B = Path(r"C:\Users\49907\coachme-bench")
LW, RW, LI, RI, LS, RS, LH, RH, NO = 15, 16, 19, 20, 11, 12, 23, 24, 0


def med(lm, f, idx, k=1):
    lo, hi = max(0, f - k), min(len(lm), f + k + 1)
    return np.nanmedian(np.nanmean(lm[lo:hi][:, idx, :2], axis=1), axis=0)


def metrics(lm, ad, top, imp, side):
    lm = lm.astype(float).copy()
    lm[~(lm[:, :, 2] >= 0.5), :2] = np.nan
    sh0, hip0 = med(lm, ad, [LS, RS], 2), med(lm, ad, [LH, RH], 2)
    torso = float(np.linalg.norm(sh0 - hip0))
    if not np.isfinite(torso) or torso < 5:
        return None
    k = 0
    h0, h1 = med(lm, ad, [LW, RW, LI, RI], 2), med(lm, imp, [LW, RW, LI, RI], k)
    hip1, sh1 = med(lm, imp, [LH, RH], k), med(lm, imp, [LS, RS], k)
    n0, n1 = med(lm, ad, [NO], 2), med(lm, imp, [NO], k)

    def tilt(sh, hip):
        v = sh - hip
        return math.degrees(math.atan2(abs(v[0]), -v[1]))
    return dict(hands_out=round(float((h1[0] - h0[0]) * side / torso), 3),
                hip_in=round(float((hip1[0] - hip0[0]) * side / torso), 3),
                spine_up=round(tilt(sh0, hip0) - tilt(sh1, hip1), 1),
                head_in=round(float((n1[0] - n0[0]) * side / torso), 3),
                spine0=round(tilt(sh0, hip0), 1))


rows = []
R = json.load(open(B / "win_v4_400" / "results_gap3.json", encoding="utf-8"))
for r in R:
    if "offset" not in r or "side" not in r or "camera" not in r:
        continue
    npy = B / "win_v4_400" / "landmarks" / f"{r['name']}.npy"
    if not npy.exists():
        continue
    ad, top, imp = r.get("address_used", r["phases"][0]), r["phases"][1], r["phases"][2]
    m = metrics(np.load(npy), ad, top, imp, r["side"])
    if m:
        m.update(name=r["name"], player=r.get("player"), slow=r.get("slow"), shoulder_width=r["camera"]["shoulder_width"],
                 hip_width=r["camera"].get("hip_width"), offset=r["offset"])
        rows.append(m)
niko = []
for rep in ("run_path_manual", "run_path_A"):
    r = json.load(open(B / "niko_clips" / "clubrep" / rep / "results.json", encoding="utf-8"))[0]
    lm = np.load(B / "niko_clips" / "clubrep" / rep / "landmarks" / f"{r['name']}.npy")
    m = metrics(lm, r["phases"][0], r["phases"][1], r["phases"][2], r["side"])
    m.update(name=r["name"], shoulder_width=r["camera"]["shoulder_width"], offset=r["offset"])
    niko.append(m)
out = {"golfdb": rows, "niko": niko}
Path(sys.argv[1]).write_text(json.dumps(out, ensure_ascii=False, indent=0, default=float), encoding="utf-8")
for key in ("hands_out", "hip_in", "spine_up", "head_in", "spine0"):
    v = np.array([r[key] for r in rows if r[key] is not None and np.isfinite(r[key])])
    print(key, "n", len(v), "p2/10/50/90/98", np.round(np.percentile(v, [2, 10, 50, 90, 98]), 3).tolist(),
          "niko", [(n["name"][:6], n[key], round(float((v < n[key]).mean() * 100), 1)) for n in niko])
sw = np.array([r["shoulder_width"] for r in rows])
for key in ("hands_out", "hip_in", "offset"):
    v = np.array([r[key] for r in rows])
    ok = np.isfinite(v)
    print("corr with shoulder_width", key, round(float(np.corrcoef(sw[ok], v[ok])[0, 1]), 3),
          "median sw<0.08", round(float(np.median(v[ok & (sw < 0.08)])), 3), "sw>=0.14", round(float(np.median(v[ok & (sw >= 0.14)])), 3),
          "n", int((ok & (sw >= 0.14)).sum()))
