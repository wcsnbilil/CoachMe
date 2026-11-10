"""Overlay for one clip: hand path, address reference line, pro band. Usage: niko_overlay.py video run_path_out layers_json out_dir"""
import sys, json
from pathlib import Path
import cv2, numpy as np
ROOT = Path(r"C:\Users\49907\coachme-bench\coachme")
sys.path.insert(0, str(ROOT / "tools" / "faults"))
from path_fault import analyze, DEFAULT_CALIBRATION as CAL

video, rp, layers, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), Path(sys.argv[4])
out.mkdir(parents=True, exist_ok=True)
cap = cv2.VideoCapture(str(video)); cap.set(cv2.CAP_PROP_ORIENTATION_AUTO, 1)
frames, ts = [], []
while True:
    ok, im = cap.read()
    if not ok: break
    frames.append(im); ts.append(cap.get(cv2.CAP_PROP_POS_MSEC) / 1000)
lms = np.load(rp / "landmarks" / f"{video.stem}.npy")
res = json.loads((rp / "results.json").read_text(encoding="utf-8"))[0]
lay = json.loads(layers.read_text(encoding="utf-8"))
phases = res.get("phases") or lay.get("phases")
report = {"decoded_frames": len(frames), "frame_hw": list(frames[0].shape[:2]),
          "dt_ms_median": round(float(np.median(np.diff(ts))) * 1000, 3),
          "run_path": {k: v for k, v in res.items() if k not in ("hands",)},
          "python_layers_phases": lay.get("phases"), "python_layers_crop": lay.get("personCrop"),
          "python_layers_nominal_fps": lay.get("nominalFPS")}
if phases:
    a, t, i = phases
    report["phase_times_s"] = [round(ts[f], 3) for f in phases]
    report["downswing_ms"] = round((ts[i] - ts[t]) * 1000, 1)
    report["backswing_ms"] = round((ts[t] - ts[a]) * 1000, 1)
    r = analyze(lms, a, t, i)
    report["reanalyse_verdict"] = r.get("verdict"); report["reanalyse_offset"] = r.get("offset")
    img = frames[t].copy()
    H, W = img.shape[:2]
    if "ref_line" in r:
        (x0, y0), (x1, y1) = r["ref_line"]; side, torso = r["side"], r["torso_px"]
        def line_pts(dx):
            ys = np.array([y0 + 0.15 * (y0 - y1), y0 + (y1 - y0) * 2.5])
            xs = x0 + (ys - y0) * (x1 - x0) / (y1 - y0) + dx
            return [(int(xs[0]), int(ys[0])), (int(xs[1]), int(ys[1]))]
        lo, hi = line_pts(CAL["inside"] * torso * side), line_pts(CAL["outside"] * torso * side)
        band = img.copy()
        cv2.fillPoly(band, [np.array([lo[0], lo[1], hi[1], hi[0]])], (200, 200, 200))
        img = cv2.addWeighted(band, 0.35, img, 0.65, 0)
        for p, c, w in ((lo, (180, 180, 180), 2), (hi, (180, 180, 180), 2), (line_pts(0), (0, 200, 0), 3)):
            cv2.line(img, p[0], p[1], c, w)
        hands = np.array(r["hands"])
        for seg, color in ((hands[a:t + 1], (255, 120, 0)), (hands[t:i + 1], (0, 0, 255))):
            seg = seg[np.isfinite(seg).all(axis=1)].astype(int)
            if len(seg) > 1: cv2.polylines(img, [seg.reshape(-1, 1, 2)], False, color, 4)
    txt = [f"{video.stem}  {W}x{H}",
           f"phases a/t/i = {a}/{t}/{i}  downswing {report['downswing_ms']:.0f} ms",
           f"offset={r.get('offset')}  (pro band {CAL['inside']}..{CAL['outside']} torso)"]
    for k, s in enumerate(txt):
        cv2.putText(img, s, (20, 50 + 45 * k), cv2.FONT_HERSHEY_SIMPLEX, 1.1, (255, 255, 255), 3)
    cv2.imwrite(str(out / "overlay_top.jpg"), cv2.resize(img, None, fx=0.6, fy=0.6), [cv2.IMWRITE_JPEG_QUALITY, 85])
    strip = [cv2.resize(frames[f], (360, int(360 * H / W))) for f in (a, t, i)]
    for s, name, f in zip(strip, ("address", "top", "impact"), phases):
        cv2.putText(s, f"{name} {f} ({ts[f]:.2f}s)", (8, 30), cv2.FONT_HERSHEY_SIMPLEX, 0.8, (0, 255, 255), 2)
    cv2.imwrite(str(out / "phases_strip.jpg"), np.hstack(strip), [cv2.IMWRITE_JPEG_QUALITY, 85])
    rng = list(range(max(0, i - 12), min(len(frames), i + 13), 3))
    near = [cv2.resize(frames[f], (180, int(180 * H / W))) for f in rng]
    for f, s in zip(rng, near):
        cv2.putText(s, str(f), (5, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
    cv2.imwrite(str(out / "impact_neighbourhood.jpg"), np.hstack(near))
    rng = list(range(max(0, t - 12), min(len(frames), t + 13), 3))
    near = [cv2.resize(frames[f], (180, int(180 * H / W))) for f in rng]
    for f, s in zip(rng, near):
        cv2.putText(s, str(f), (5, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
    cv2.imwrite(str(out / "top_neighbourhood.jpg"), np.hstack(near))
(out / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=1, default=float), encoding="utf-8")
print(json.dumps({k: v for k, v in report.items() if k != "run_path"}, ensure_ascii=False, default=float))
print(json.dumps({k: v for k, v in report["run_path"].items() if k not in ("offset_by_height",)}, ensure_ascii=False, default=float)[:2000])
