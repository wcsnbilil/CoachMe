"""How much a regression metric could move by chance: bootstrap intervals over the clips (or pairs) it averages.

The gates stay exact (any drop fails); these numbers only say whether a change is bigger than what
resampling the same few hundred clips would give. Fixed seed, so the printed text is reproducible.
"""
import numpy as np

DRAWS = 4000
SEED = 0


def interval(values):
    """95% percentile bootstrap interval of the mean of per-unit values."""
    values = np.asarray(list(values), dtype=float)
    if len(values) == 0:
        return float("nan"), float("nan")
    rng = np.random.default_rng(SEED)
    means = values[rng.integers(0, len(values), size=(DRAWS, len(values)))].mean(axis=1)
    return float(np.percentile(means, 2.5)), float(np.percentile(means, 97.5))


def paired(before, after):
    """Mean change over the units both sides have, its 95% paired bootstrap interval, and how many units got better / worse."""
    shared = sorted(set(before) & set(after))
    change = np.asarray([after[k] - before[k] for k in shared], dtype=float)
    lo, hi = interval(change)
    return {"units": len(shared), "change": float(change.mean()) if len(change) else float("nan"), "low": lo, "high": hi,
            "better": int((change > 0).sum()), "worse": int((change < 0).sum())}


def describe_interval(values, unit):
    lo, hi = interval(values)
    return f"95% 区间 {lo:.4f}–{hi:.4f}（按{unit}重抽样）"


def describe_paired(before, after, unit):
    p = paired(before, after)
    return (f"按{unit}配对：变化 {p['change']:+.4f}，95% 区间 {p['low']:+.4f} – {p['high']:+.4f}；"
            f"{p['units']} 个{unit}里变好 {p['better']}、变差 {p['worse']}")
