"""Python port of CoachMeCore's SwingNetEventSelector (Phases/SwingNetEventSelector.swift).

Keep the two in step: the GolfDB benchmark uses this port to score what the
app would actually show, not only SwingNet's raw per-event argmax.
"""

import math

# GolfDB event index -> CoachMe phase. Event 6 (mid-follow-through) is unused by the app.
MAPPING = [(0, "address"), (2, "midBackswing"), (3, "top"), (4, "midDownswing"), (5, "impact"), (7, "finish")]
TAKEAWAY = (1, "takeaway")
APP_EVENTS = [0, 1, 2, 3, 4, 5, 7]


class SwingNetEventSelector:
    def __init__(self):
        self.scores = [-math.inf] * 8
        self.times = [None] * 8
        self.boundaries = []  # (time, address, finish, takeaway)
        self.last = None

    def append(self, probabilities, timestamp):
        if (len(probabilities) != 9 or not math.isfinite(timestamp)
                or not all(math.isfinite(p) and 0 <= p <= 1 for p in probabilities)
                or (self.last is not None and not timestamp > self.last)):
            raise ValueError("invalid prediction")
        self.last = timestamp
        self.boundaries.append((timestamp, probabilities[0], probabilities[7], probabilities[1]))
        for e in range(8):
            if probabilities[e] > self.scores[e]:
                self.scores[e] = probabilities[e]
                self.times[e] = timestamp

    def keyframes(self):
        """Returns {phase: (time, score)} or {} when the app would show no automatic marks."""
        times, scores = list(self.times), list(self.scores)
        interior = [times[i] for i in (2, 3, 4, 5) if times[i] is not None]
        if len(interior) != 4 or not all(a < b for a, b in zip(interior, interior[1:])):
            return {}
        if times[0] is None or times[0] >= interior[0]:
            cands = [b for b in self.boundaries if b[0] < interior[0] and b[1] > 0]
            if not cands:
                return {}
            best = max(cands, key=lambda b: b[1])
            times[0], scores[0] = best[0], best[1]
        if times[7] is None or times[7] <= interior[3]:
            cands = [b for b in self.boundaries if b[0] > interior[3] and b[2] > 0]
            if not cands:
                return {}
            best = max(cands, key=lambda b: b[2])
            times[7], scores[7] = best[0], best[2]
        selected = [times[e] for e, _ in MAPPING]
        if any(t is None for t in selected) or not all(a < b for a, b in zip(selected, selected[1:])):
            return {}
        mapping = list(MAPPING)
        cands = [b for b in self.boundaries if times[0] < b[0] < times[2] and b[3] > 0]
        if cands:
            best = max(cands, key=lambda b: b[3])
            times[1], scores[1] = best[0], best[3]
            mapping.insert(1, TAKEAWAY)
        return {phase: (times[e], scores[e]) for e, phase in mapping}


def softmax(row):
    m = max(row)
    ex = [math.exp(v - m) for v in row]
    s = sum(ex)
    return [v / s for v in ex]
