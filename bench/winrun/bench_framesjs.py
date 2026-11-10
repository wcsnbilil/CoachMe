"""Write pose_bench/frames.js for label.html: frames with torso >= 120 px; set 'niko30' = 10 per view."""
import json, random
from pathlib import Path
OUT = Path(r"C:\Users\49907\coachme-bench\pose_bench")
man = [m for m in json.load(open(OUT / "manifest.json", encoding="utf-8")) if m["torso_px"] >= 120]
random.seed(11)
niko = set()
for v in ("dtl", "face_on", "angle"):
    xs = [m for m in man if m["view"] == v]
    seen, pick = set(), []
    for m in random.sample(xs, len(xs)):  # one frame per video where possible
        vid = m["id"].rsplit("_", 1)[0]
        if vid in seen: continue
        seen.add(vid); pick.append(m["id"])
        if len(pick) == 10: break
    niko |= set(pick)
fr = [{"id": m["id"], "view": m["view"], "sets": ["niko30"] if m["id"] in niko else []} for m in man]
(OUT / "frames.js").write_text("window.FRAMES = " + json.dumps(fr) + ";", encoding="utf-8")
print(len(fr), "frames;", len(niko), "in niko30", {v: sum(1 for m in man if m["view"] == v) for v in ("dtl", "face_on", "angle")})
