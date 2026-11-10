"""Build multi-swing test sequences from the GolfDB parity landmarks and score swing_split on them.

Each case is a real single-swing GolfDB landmark track, or 2-5 of them joined the way a range session
looks: finish -> lower the club over 1.5-3 s -> (optionally step to a new spot) -> stand at address ->
next swing. Every clip is rescaled to the same body size first. Higher frame rates are the same
motion resampled (linear interpolation), with pixel noise.

  python tools/split/make_split_parity.py tools/faults/fixtures/path_parity.json --out /tmp/split.json

Writes the cases with the Python swings/windows (for the Swift parity test, COACHME_SPLIT_PARITY)
and prints how often the swing count is exactly right (and every swing is located). Exit 1 when
a group's count rate is below --min-exact.
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import swing_split as ss  # noqa: E402

JOINTS = [ss.LS, ss.RS, ss.LW, ss.RW, ss.LH, ss.RH]  # all the splitter reads


def load(path: Path) -> list[dict]:
    swings = json.loads(path.read_text(encoding="utf-8"))
    for s in swings:
        s["lm"] = np.array([[[np.nan if v is None else v for v in pt] for pt in fr] for fr in s["landmarks"]], float)
    return swings


def normalise(a: np.ndarray) -> np.ndarray:
    x = a.copy()
    x[~(x[:, :, 2] >= 0.5), :2] = np.nan
    sh = np.nanmean(x[:, [11, 12], :2], 1)
    hip = np.nanmean(x[:, [23, 24], :2], 1)
    t = np.nanmedian(np.linalg.norm(sh - hip, axis=1))
    c = np.nanmedian(hip, 0)
    out = a.copy()
    out[:, :, :2] = (a[:, :, :2] - c) / t * 120 + [360, 600]
    return out


def stretch(a: np.ndarray, f: int) -> np.ndarray:
    if f == 1:
        return a
    t = np.arange((len(a) - 1) * f + 1) / f
    i = np.floor(t).astype(int)
    w = (t - i)[:, None, None]
    j = np.minimum(i + 1, len(a) - 1)
    return a[i] * (1 - w) + a[j] * w


def join(clips: list[dict], rng: random.Random, walk: bool) -> tuple[np.ndarray, list[int]]:
    parts, tops, off = [], [], 0
    for s in clips:
        a = normalise(s["lm"])
        if parts:
            prev = parts[-1][-1]
            base = a[:1].copy()
            if walk:
                base[:, :, 0] += rng.uniform(-150, 150)
            m = rng.randint(45, 90)
            w = np.linspace(0, 1, m)[:, None, None]
            w2 = np.linspace(0, 1, 15)[:, None, None]
            gap = np.concatenate([prev[None] * (1 - w) + base * w,
                                  np.repeat(base, rng.randint(10, 60), 0),
                                  base * (1 - w2) + a[:1] * w2])
            gap[:, :, 2] = 1.0
        else:
            gap = a[:0]
        tops.append(off + len(gap) + s["phases"][1])
        a = np.concatenate([gap, a])
        parts.append(a)
        off += len(a)
    return np.concatenate(parts), tops


def cases(swings: list[dict]) -> list[dict]:
    rng = random.Random(7)
    nrng = np.random.default_rng(7)
    out = []
    for s in swings:
        out.append(dict(name=f"single_{s['name']}", fps=30, lm=s["lm"], tops=[s["phases"][1]], single=True))
    # 15 fps = every other frame of a 30 fps sequence: what the app's quick first pass sees
    for fps, n, walk, noise in [(30, 60, False, 0.0), (30, 40, True, 2.4), (60, 30, False, 1.2), (240, 15, True, 0.6),
                                (15, 40, False, 1.2), (15, 30, True, 2.4)]:
        f = max(1, fps // 30)
        skip = 30 // fps if fps < 30 else 1
        for k in range(n):
            grp = rng.sample(swings, rng.randint(2, 5))
            lm, tops = join(grp, rng, walk)
            lm = stretch(lm, f)
            lm[:, :, :2] += nrng.normal(0, noise, lm[:, :, :2].shape) if noise else 0
            out.append(dict(name=f"join{fps}_{'walk_' if walk else ''}{k}_" + "+".join(g["name"][7:] for g in grp),
                            fps=fps, lm=lm[::skip], tops=[t * f // skip for t in tops], single=False))
    for s in swings:
        out.append(dict(name=f"single15_{s['name']}", fps=15, lm=s["lm"][::2], tops=[s["phases"][1] // 2], single=True))
    return out


def located(case: dict, found: list[tuple[int, int, int]]) -> bool:
    """Every true top lies inside a found address..impact span (a few frames of slack)."""
    tol = max(2, 5 * case["fps"] // 30)
    return all(any(a - tol <= t <= i + tol for a, _, i in found) for t in case["tops"])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fixture", type=Path)
    ap.add_argument("--out", type=Path)
    ap.add_argument("--min-exact", type=float, default=0.95, help="per group, share with the exact count")
    a = ap.parse_args()
    groups: dict[str, list[tuple[bool, bool]]] = {}
    rows = []
    for c in cases(load(a.fixture)):
        # rounded first so Python and Swift see exactly the same numbers
        lm = np.where(np.isfinite(c["lm"]), np.round(c["lm"], 3), np.nan)
        found = ss.find_swings(lm, c["fps"])
        count_ok = len(found) == len(c["tops"])
        loc_ok = count_ok and located(c, found)
        g = c["name"].split("_")[0] + ("_walk" if "_walk_" in c["name"] else "")
        groups.setdefault(g, []).append((count_ok, loc_ok))
        if not loc_ok:
            print(f"  {'count' if not count_ok else 'place'} {c['name']}: expected {len(c['tops'])} "
                  f"(tops {c['tops']}), found {found}")
        rows.append(dict(name=c["name"], fps=c["fps"], expected=len(c["tops"]),
                         swings=[list(map(int, s)) for s in found],
                         windows=[list(map(int, w)) for w in ss.windows(found, len(lm), c["fps"])],
                         single_windows=[list(map(int, w)) for w in ss.windows(found, len(lm), c["fps"], single=True)],
                         joints=JOINTS,
                         landmarks=[[[None if not np.isfinite(v) else float(v) for v in fr[j]] for j in JOINTS]
                                    for fr in lm]))
    failed = False
    for g, r in groups.items():
        n, cnt, loc = len(r), sum(x for x, _ in r), sum(y for _, y in r)
        print(f"{g:14s} swing count right {cnt}/{n} ({cnt / n:.0%}), every swing located {loc}/{n} ({loc / n:.0%})")
        failed |= cnt / n < a.min_exact
    if a.out:
        a.out.write_text(json.dumps(rows), encoding="utf-8")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
