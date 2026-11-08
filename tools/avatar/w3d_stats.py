"""Stats for the 3D-skeleton check. usage: python w3d_stats.py <w3d dir>"""
import json, sys, math, collections
from pathlib import Path
import numpy as np
d = Path(sys.argv[1]); rows = []
def yaw(W, f, a, b):
    v = W[f, b, :3] - W[f, a, :3]
    return math.degrees(math.atan2(v[2], v[0]))
def wrap(x): return (x + 180) % 360 - 180
def med(W, f, a, b, h=1):
    fs = range(max(0, f - h), min(len(W), f + h + 1))
    return np.nanmedian([wrap(yaw(W, g, a, b) - yaw(W, fs[0], a, b)) + yaw(W, fs[0], a, b) for g in fs])
for js in sorted(d.glob("*.json")):
    m = json.loads(js.read_text(encoding="utf-8")); W = np.load(js.with_suffix(".npy"))
    a, t, i = m["phases"]
    if t >= len(W) or not np.isfinite(W[[a, t], :, 0]).all(): continue
    W = W.copy(); W[W[:, :, 3] < 0.5, :3] = np.nan
    sh = abs(wrap(med(W, t, 11, 12) - med(W, a, 11, 12)))
    hp = abs(wrap(med(W, t, 23, 24) - med(W, a, 23, 24)))
    seg = W[a:i + 1]
    def cv(p, q):
        L = np.linalg.norm(seg[:, p, :3] - seg[:, q, :3], axis=1); L = L[np.isfinite(L)]
        return float(np.std(L) / np.mean(L)) if len(L) > 5 else np.nan, float(np.median(L)) if len(L) else np.nan
    fa_cv, fa_len = cv(13, 15); ua_cv, ua_len = cv(11, 13)
    # depth range of the hands during the swing vs image-plane range
    hands = np.nanmean(seg[:, [15, 16], :3], 1)
    rows.append({"name": js.stem, "view": m["view"], "src": m.get("src", "golfdb"), "slow": m.get("slow"), "yt": m.get("youtube_id"), "player": m.get("player"),
                 "shoulder_turn": sh, "hip_turn": hp, "forearm_cv": fa_cv, "forearm_m": fa_len, "upperarm_cv": ua_cv,
                 "hand_depth_range": float(np.nanmax(hands[:, 2]) - np.nanmin(hands[:, 2])), "hand_x_range": float(np.nanmax(hands[:, 0]) - np.nanmin(hands[:, 0]))})
grp = collections.defaultdict(list)
for r in rows: grp[(r["src"], r["view"])].append(r)
q = lambda v: np.round(np.nanpercentile(v, [10, 50, 90]), 2).tolist()
for k, rs in sorted(grp.items()):
    print(f"== {k} n={len(rs)}")
    for f in ("shoulder_turn", "hip_turn", "forearm_cv", "upperarm_cv", "forearm_m", "hand_depth_range", "hand_x_range"):
        print(f"  {f:17s} p10/50/90 {q([r[f] for r in rs])}")
    sh = np.array([r["shoulder_turn"] for r in rs]); hp = np.array([r["hip_turn"] for r in rs])
    print(f"  shoulder turn in 75-115 deg: {int(((sh>=75)&(sh<=115)).sum())}/{len(rs)}; hip turn in 30-65: {int(((hp>=30)&(hp<=65)).sum())}/{len(rs)}; shoulder>hip: {int((sh>hp).sum())}/{len(rs)}")
pairs = collections.defaultdict(dict)
for r in rows:
    if r["slow"] is not None: pairs[(r["yt"], r["player"], r["view"])][r["slow"]] = r
pd_ = [(g[0]["shoulder_turn"], g[1]["shoulder_turn"]) for g in pairs.values() if 0 in g and 1 in g]
if pd_: print("real-time vs slow-mo same swing, shoulder turn |diff| p50/p90:", np.round(np.percentile([abs(x - y) for x, y in pd_], [50, 90]), 1).tolist(), "n", len(pd_))
json.dump(rows, open(d / "w3d_stats.json", "w"), indent=0)
