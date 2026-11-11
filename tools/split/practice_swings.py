"""What does the splitter do with practice swings? (report only, nothing is gated)

On the range a real shot is often followed by a rehearsal without a ball, and the app analyses the
last swing it finds. Sequences here are GolfDB swings joined as in make_split_parity, where the
"practice" swing is the same kind of track with the arms' travel from address scaled down (half /
three-quarter swing), played slower, or left as is (a full-speed rehearsal looks exactly like a shot
to a pose-only rule). Seen at 15 fps, like the app's first pass.

  python tools/split/practice_swings.py tools/faults/fixtures/path_parity.json
"""
from __future__ import annotations

import random
import sys
from collections import Counter
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_split_parity as mp  # noqa: E402
import swing_split as ss  # noqa: E402

ARMS = list(range(13, 23))


def practice(s: dict, reach: float, slower: float) -> dict:
    lm = s["lm"].copy()
    ad = s["phases"][0]
    lm[:, ARMS, :2] = lm[ad, ARMS, :2] + (lm[:, ARMS, :2] - lm[ad, ARMS, :2]) * reach
    if slower != 1.0:
        t = np.arange(int((len(lm) - 1) * slower) + 1) / slower
        i = np.floor(t).astype(int)
        w = (t - i)[:, None, None]
        lm = lm[i] * (1 - w) + lm[np.minimum(i + 1, len(lm) - 1)] * w
    return dict(name=s["name"], lm=lm, phases=[int(p * slower) for p in s["phases"]])


def main():
    swings = [s for s in mp.load(Path(sys.argv[1])) if s["phases"][1] - s["phases"][0] < 45]  # real-time clips
    rng = random.Random(11)
    kinds = [("半挥（手到一半高）", 0.5, 1.0), ("四分之三挥", 0.75, 1.0), ("全挥但放慢 1.5 倍", 1.0, 1.5), ("全速空挥", 1.0, 1.0)]
    print("| 序列 | 段数 | 找到的次数 | 选中的最后一杆是真杆 | 选中的是试挥 | 没切（整段分析） |")
    print("|---|---|---|---|---|---|")
    for label, reach, slower in kinds:
        for real_first in (True, False):
            found_n, real, rehearsal, whole = Counter(), 0, 0, 0
            n = 30
            for _ in range(n):
                a, b = rng.sample(swings, 2)
                grp = [a, practice(b, reach, slower)] if real_first else [practice(b, reach, slower)]
                lm, tops = mp.join(grp, rng, False) if len(grp) > 1 else (mp.normalise(grp[0]["lm"]), [grp[0]["phases"][1]])
                f = ss.find_swings(lm[::2], 15)
                found_n[len(f)] += 1
                if not f:
                    whole += 1
                elif real_first and abs(f[-1][1] - tops[0] // 2) <= 5:
                    real += 1
                else:
                    rehearsal += 1
            name = ("真杆 + " if real_first else "只有") + label
            print(f"| {name} | {n} | {'，'.join(f'{k} 次×{v}' for k, v in sorted(found_n.items()))} | "
                  f"{real if real_first else '—'} | {rehearsal} | {whole} |")


if __name__ == "__main__":
    main()
