"""Skeleton benchmark summary from pose_bench/preds.json: per model detection rate, jitter, speed.
  detection rate = share of the 12 body joints (shoulders..ankles) with score >= THR[model], over all frames
                   (also the share of frames with all 12). Scores are each model's own confidence, not comparable 1:1.
  jitter         = median |p(k) - (p(k-1)+p(k+1))/2| / torso over joints confident in all three frames.
                   Includes real acceleration (same for all models, frames are mostly downswing), so compare models, not absolutes.
                   MediaPipe values come from VIDEO mode (its own temporal smoothing); RTMW / ViTPose are per-frame.
  speed          = mean ms per frame on this PC (first 5 frames dropped as warm-up). RTMW / ViTPose exclude the YOLOX
                   person detector (listed separately); MediaPipe is timed in IMAGE mode on CPU at 540 px height.
No ground truth here: accuracy needs the hand labels from pose_bench/label.html.
Output: pose_bench/report.md + report.json"""
import json, os
from pathlib import Path
import numpy as np

OUT = Path(os.environ.get("CM_POSE_OUT", r"C:\Users\k8881\coachme-bench\pose_bench"))
man = {m["id"]: m for m in json.load(open(OUT / "manifest.json", encoding="utf-8"))}
preds = json.load(open(OUT / "preds.json", encoding="utf-8"))
J = ["l_sh", "r_sh", "l_el", "r_el", "l_wr", "r_wr", "l_hip", "r_hip", "l_knee", "r_knee", "l_ank", "r_ank"]
THR = {"mediapipe": 0.5, "rtmw": 0.3, "vitpose_h": 0.3}
rep = {}
for model, thr in THR.items():
    det, full, jit, jit_wr, ms, nframes = [], [], [], [], [], 0
    by_view = {}
    for fid, p in preds.items():
        if "error" in p: continue
        nframes += 1
        cur = p.get(model)
        if not cur:
            det += [0] * len(J); full.append(0); by_view.setdefault(man[fid]["view"], []).extend([0] * len(J)); continue
        good = [bool(np.isfinite(cur[j][0]) and cur[j][2] >= thr) for j in J]
        det += good; full.append(all(good)); by_view.setdefault(man[fid]["view"], []).extend(good)
        if "ms" in p and model in p["ms"]: ms.append(p["ms"][model])
        a, b = p.get("prev", {}).get(model), p.get("next", {}).get(model)
        torso = man[fid]["torso_px"]
        if a and b:
            for j in J:
                if min(cur[j][2], a[j][2], b[j][2]) >= thr and np.isfinite([cur[j][0], a[j][0], b[j][0]]).all():
                    d = np.hypot(cur[j][0] - (a[j][0] + b[j][0]) / 2, cur[j][1] - (a[j][1] + b[j][1]) / 2) / torso
                    jit.append(d)
                    if j.endswith("_wr"): jit_wr.append(d)
    rep[model] = {"frames": nframes, "joint_detection_rate": round(float(np.mean(det)), 4) if det else None,
                  "all12_frame_rate": round(float(np.mean(full)), 4) if full else None,
                  "detection_by_view": {v: round(float(np.mean(x)), 4) for v, x in by_view.items()},
                  "jitter_median_torso": round(float(np.median(jit)), 5) if jit else None,
                  "jitter_p90_torso": round(float(np.percentile(jit, 90)), 5) if jit else None,
                  "jitter_wrist_median_torso": round(float(np.median(jit_wr)), 5) if jit_wr else None,
                  "ms_per_frame": round(float(np.mean(ms[5:] or ms)), 1) if ms else None, "score_threshold": thr}
det_ms = [p["ms"]["yolox_det"] for p in preds.values() if "ms" in p and "yolox_det" in p["ms"]]
rep["_yolox_det_ms"] = round(float(np.mean(det_ms[5:] or det_ms)), 1) if det_ms else None
(OUT / "report.json").write_text(json.dumps(rep, indent=1), encoding="utf-8")
lines = [f"# Skeleton model comparison ({len(preds)} frames)", "", __doc__.split("Output:")[0].strip(), "",
         "| model | joints detected | frames with all 12 | jitter median (torso) | jitter p90 | wrist jitter median | ms / frame |",
         "|---|---|---|---|---|---|---|"]
for m in THR:
    r = rep[m]
    lines.append(f"| {m} | {r['joint_detection_rate']} | {r['all12_frame_rate']} | {r['jitter_median_torso']} | "
                 f"{r['jitter_p90_torso']} | {r['jitter_wrist_median_torso']} | {r['ms_per_frame']} |")
lines += ["", f"YOLOX person detector (shared by RTMW and ViTPose): {rep['_yolox_det_ms']} ms / frame", "",
          "Detection by view: " + json.dumps({m: rep[m]["detection_by_view"] for m in THR})]
(OUT / "report.md").write_text("\n".join(lines), encoding="utf-8")
print("\n".join(lines))
