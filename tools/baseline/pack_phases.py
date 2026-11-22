"""Packs SwingNet's per-frame probabilities on a GolfDB split into the phase regression baseline's format.

  python3 tools/benchmark/golfdb_eval.py --golfdb <data> --split 1 --save-probs probs
  python3 tools/baseline/pack_phases.py probs <golfDB.pkl> --split 1 --out baseline/golfdb-split1-phases

Output:
  swings.json         one entry per clip: id, view, slow, frames, events (GolfDB's 10 frame numbers relative
                      to the first: clip start, the 8 labelled events, clip end), offset (index of the
                      clip's first value in probabilities.u16)
  probabilities.u16   little-endian uint16, per clip frames x CLASSES: probability times SCALE, rounded
"""
import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

SCALE = 65535
CLASSES = 9


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("probs", type=Path)
    ap.add_argument("pkl", type=Path)
    ap.add_argument("--split", type=int, default=1)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()

    table = pd.read_pickle(a.pkl)
    table = table[table["split"] == a.split]
    swings, blocks, offset = [], [], 0
    for row in table.itertuples():
        path = a.probs / f"{row.id}.npy"
        if not path.exists():
            raise SystemExit(f"{path} is missing: the evaluation did not cover every clip of split {a.split}")
        probs = np.load(path)
        if probs.ndim != 2 or probs.shape[1] != CLASSES or not np.isfinite(probs).all():
            raise SystemExit(f"{path}: expected finite [frames, {CLASSES}] probabilities, got {probs.shape}")
        events = [int(e) - int(row.events[0]) for e in row.events]
        swings.append({"id": int(row.id), "view": str(row.view), "slow": int(row.slow),
                       "frames": int(probs.shape[0]), "events": events, "offset": offset})
        blocks.append(np.rint(np.clip(probs, 0, 1) * SCALE).astype("<u2").reshape(-1))
        offset += blocks[-1].size

    a.out.mkdir(parents=True, exist_ok=True)
    np.concatenate(blocks).tofile(a.out / "probabilities.u16")
    manifest = {"version": 1, "split": a.split, "scale": SCALE, "classes": CLASSES, "swings": swings}
    (a.out / "swings.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(swings)} clips, {offset} values -> {a.out}")


if __name__ == "__main__":
    main()
