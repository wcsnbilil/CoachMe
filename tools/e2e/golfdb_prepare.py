"""Pick the GolfDB clips run_path.py --golfdb --limit N would use (down-the-line, file order) and
copy them to one folder for the App test.

  python tools/e2e/golfdb_prepare.py <GolfDB data dir> --limit 400 --out golfdb-clips
"""
from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import pandas as pd


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("golfdb", type=Path)
    ap.add_argument("--limit", type=int, default=400)
    ap.add_argument("--out", type=Path, default=Path("golfdb-clips"))
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    df = pd.read_pickle(a.golfdb / "golfDB.pkl")
    df = df[df["view"] == "down-the-line"].head(a.limit)
    for row in df.itertuples():
        shutil.copy(a.golfdb / "videos_160" / f"{row.id}.mp4", a.out / f"golfdb_{row.id}.mp4")
    print(f"{len(df)} clips -> {a.out}")


if __name__ == "__main__":
    main()
