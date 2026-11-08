"""Compare two run_path.py results.json files (before / after a change).

  python tools/faults/compare.py old/results.json new/results.json --golfdb ~/coachme-bench/golfdb/data

Prints verdict counts, how often the real-time and slow-motion copy of the
same swing agree, whether golfers with several clips stay consistent, the
verdicts that changed, and the lefties (side = -1 if the ball is on the left).
"""

from __future__ import annotations

import argparse
import json
import sys
from collections import Counter, defaultdict
from pathlib import Path


def load(path: Path, meta: dict | None = None) -> dict:
    rows = {r["name"]: r for r in json.loads(path.read_text(encoding="utf-8"))}
    for name, r in rows.items():  # results from the first version carry no player / slow fields
        for k, v in (meta or {}).get(name, {}).items():
            r.setdefault(k, v)
    return rows


def pair_agreement(rows: dict) -> tuple[int, int, list]:
    """Real-time and slow-motion copies share youtube_id and player."""
    groups = defaultdict(dict)
    for r in rows.values():
        if "slow" in r:
            groups[(r.get("youtube_id"), r.get("player"))][r["slow"]] = r
    agree = total = 0
    bad = []
    for g in groups.values():
        if 0 in g and 1 in g and "offset" in g[0] and "offset" in g[1]:
            total += 1
            if g[0]["verdict"] == g[1]["verdict"]:
                agree += 1
            else:
                bad.append((g[0]["name"], g[0]["offset"], g[1]["name"], g[1]["offset"]))
    return agree, total, bad


def golfer_consistency(rows: dict) -> list:
    by = defaultdict(list)
    for r in rows.values():
        if r.get("player") and "offset" in r:
            by[r["player"]].append(r["verdict"])
    out = []
    for player, v in by.items():
        if len(v) >= 3:
            top, n = Counter(v).most_common(1)[0]
            out.append((player, len(v), top, n / len(v)))
    return sorted(out, key=lambda x: x[3])


def report(tag: str, rows: dict):
    print(f"\n== {tag}: {len(rows)} swings")
    print(" verdicts", dict(Counter(r["verdict"] for r in rows.values())))
    print(" reasons", dict(Counter(r["reason"] for r in rows.values() if "reason" in r)))
    agree, total, bad = pair_agreement(rows)
    if total:
        slow_more_out = sum(1 for _, o0, _, o1 in bad if o1 > o0)
        print(f" real-time vs slow-mo agree {agree}/{total} = {agree / total:.0%}; "
              f"of {len(bad)} disagreements slow-mo more 外下 in {slow_more_out}")
    cons = golfer_consistency(rows)
    if cons:
        print(" golfers with >=3 clips, least consistent first:")
        for player, n, top, share in cons[:8]:
            print(f"   {player:22s} {n} clips, {top} {share:.0%}")
    lefties = sorted({r.get("player", r["name"]) for r in rows.values() if r.get("side") == -1})
    print(" side=-1 (ball on the left):", ", ".join(lefties) or "none")


def main():
    if hasattr(sys.stdout, "reconfigure"):  # Windows console defaults to GBK/cp1252
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser()
    p.add_argument("before", type=Path)
    p.add_argument("after", type=Path)
    p.add_argument("--golfdb", type=Path, help="GolfDB data dir, fills player/slow for older results.json")
    a = p.parse_args()
    meta = None
    if a.golfdb:
        import pandas as pd
        df = pd.read_pickle(a.golfdb / "golfDB.pkl")
        meta = {f"golfdb_{r.id}": {"player": r.player, "slow": int(r.slow), "youtube_id": r.youtube_id}
                for r in df.itertuples()}
    old, new = load(a.before, meta), load(a.after, meta)
    report("before", old)
    report("after", new)
    changed = [(n, old[n]["verdict"], old[n].get("offset"), new[n]["verdict"], new[n].get("offset"))
               for n in sorted(set(old) & set(new)) if old[n]["verdict"] != new[n]["verdict"]]
    print(f"\n== {len(changed)} verdicts changed")
    for n, v0, o0, v1, o1 in changed:
        print(f"   {n:14s} {str(new[n].get('player', '')):20s} {v0} {o0} -> {v1} {o1}")


if __name__ == "__main__":
    main()
