"""Run target_line.py on one swing per video from hd_part0-3 (pro DTL clips) to check stick false positives."""
import json, subprocess, sys
from pathlib import Path
B = Path(r"C:\Users\49907\coachme-bench")
OUT = B / "target_pro"; OUT.mkdir(exist_ok=True)
seen, rows = set(), []
for p in range(4):
    for r in json.load(open(B / f"hd_part{p}/results.json", encoding="utf-8")):
        v = r["video"]
        if v in seen: continue
        seen.add(v); rows.append(r)
rows = rows[: int(sys.argv[1])]
summ = []
for r in rows:
    ad, top, imp = r["phases"]
    cmd = [sys.executable, str(B / "winrun/target_line.py"), r["video"], r["lm"], "--address", str(ad),
           "--search-to", str(imp + 25), "--out", str(OUT)]
    res = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    line = res.stdout.strip().splitlines()[-1] if res.stdout.strip() else res.stderr.strip().splitlines()[-1]
    try:
        j = json.loads(line)
    except ValueError:
        j = {"error": line[-200:]}
    j["name"] = r["name"]; summ.append(j)
    print(r["name"], j.get("target", {}).get("source"), j.get("target", {}).get("camera_axis_offset_deg"),
          j.get("fps_capture"), j.get("impact"), j.get("club_direction", {}).get("status"), j.get("error", ""), flush=True)
(OUT / "summary.json").write_text(json.dumps(summ, indent=1, default=float), encoding="utf-8")
