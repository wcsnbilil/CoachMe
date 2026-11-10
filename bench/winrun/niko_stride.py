"""SwingNet on a 120fps clip at stride 1/2/4 (120/60/30 fps). Phases mapped back to original frame numbers."""
import sys
from pathlib import Path
import numpy as np
ROOT = Path(r"C:\Users\49907\coachme-bench\coachme")
sys.path.insert(0, str(ROOT / "tools" / "benchmark"))
from golfdb_eval import load_model, probabilities, read_frames
from person_crop import phases_from_probs
names = ['address', 'toe-up', 'mid-back', 'top', 'mid-down', 'impact', 'mid-follow', 'finish']
m = load_model("numpy")
fr = read_frames(Path(sys.argv[1]))
for s in (1, 2, 4):
    for off in range(s):
        sub = fr[off::s]
        p = probabilities(m, sub)
        ph = phases_from_probs(p)
        peaks = {n: int(np.argmax(p[:, e])) * s + off for e, n in enumerate(names)}
        print(f"stride {s} off {off}: phases {None if ph is None else [x * s + off for x in ph]} peaks {peaks}")
    # chunk boundary effect at stride 1: also shift start so the last chunk is full
    if s == 1:
        for start in (537 - 512, 537 - 448):
            p = probabilities(m, fr[start:])
            ph = phases_from_probs(p)
            print(f"stride 1 start {start}: phases {None if ph is None else [x + start for x in ph]}")
