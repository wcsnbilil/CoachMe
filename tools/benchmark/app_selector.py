"""Python port of CoachMeCore's SwingNetEventSelector (Phases/SwingNetEventSelector.swift).

Keep the two in step: the GolfDB benchmark uses this port to score what the
app would actually show, not only SwingNet's raw per-event argmax.

The eight GolfDB events are picked together, in strictly increasing frames, maximising the product of their
probabilities (each floored at probabilityFloor). If the geometric mean of those eight probabilities is below
exp(minMeanLogProbability) the video is treated as not one complete swing and gets no marks. Products and
comparisons only, so Swift and Python pick the same frames bit for bit.
"""

import json
import math
from pathlib import Path

_T = json.loads((Path(__file__).resolve().parents[2] / "config" / "thresholds.json").read_text(encoding="utf-8"))["swingPhases"]

# GolfDB event index -> CoachMe phase. Event 6 (mid-follow-through) is ordered but not shown.
MAPPING = [(0, "address"), (1, "takeaway"), (2, "midBackswing"), (3, "top"), (4, "midDownswing"), (5, "impact"),
           (7, "finish")]
APP_EVENTS = [0, 1, 2, 3, 4, 5, 7]
EVENTS = 8


class SwingNetEventSelector:
    def __init__(self):
        self.rows = []
        self.timestamps = []

    def append(self, probabilities, timestamp):
        if (len(probabilities) != 9 or not math.isfinite(timestamp)
                or not all(math.isfinite(p) and 0 <= p <= 1 for p in probabilities)
                or (self.timestamps and not timestamp > self.timestamps[-1])):
            raise ValueError("invalid prediction")
        self.timestamps.append(timestamp)
        self.rows.append(list(probabilities[:EVENTS]))

    def keyframes(self):
        """Returns {phase: (time, score)} or {} when the app would show no automatic marks."""
        frames, product = ordered(self.rows)
        if frames is None or math.log(product) / EVENTS < _T["minMeanLogProbability"]:
            return {}
        return {phase: (self.timestamps[frames[e]], self.rows[frames[e]][e]) for e, phase in MAPPING}


def ordered(rows):
    """Frames f0 < f1 < ... < f7 maximising prod rows[f_e][e]; earliest frame on ties. (None, 0) if too short."""
    if len(rows) < EVENTS:
        return None, 0.0
    rows = [[max(p, _T["probabilityFloor"]) for p in row] for row in rows]
    best = [row[0] for row in rows]
    back = []
    for e in range(1, EVENTS):
        nxt, arg = [0.0] * len(rows), [0] * len(rows)
        running, at = 0.0, 0
        for t, row in enumerate(rows):
            if running > 0:
                nxt[t], arg[t] = running * row[e], at
            if best[t] > running:
                running, at = best[t], t
        best = nxt
        back.append(arg)
    t = max(range(len(rows)), key=lambda i: (best[i], -i))
    product, frames = best[t], [t]
    for arg in reversed(back):
        t = arg[t]
        frames.append(t)
    return frames[::-1], product


def softmax(row):
    m = max(row)
    ex = [math.exp(v - m) for v in row]
    s = sum(ex)
    return [v / s for v in ex]
