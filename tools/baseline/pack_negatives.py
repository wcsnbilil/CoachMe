"""Packs SwingNet's per-frame probabilities on videos that are not one complete swing, cut from GolfDB split 1.

  python3 tools/baseline/pack_negatives.py <GolfDB data dir> --out baseline/golfdb-split1-negatives

Each split 1 clip is encoded once; the cuts below reuse its per-frame features (the encoder sees one frame at a
time, so this equals encoding the cut video) and run the sequence model on them in 64-frame chunks like the app.
Events are GolfDB's, relative to the clip start: 1 address, 2 takeaway, 4 top, 6 impact.

  standing           start .. before takeaway        no swing at all
  backswingOnly      start .. top                    recording stops at the top
  followThroughOnly  after impact .. end             recording starts after impact
  reversed           the whole clip backwards
  still              the address frame held for 64 frames
  twoSwings          the previous clip, then this one

Output (same probability encoding as pack_phases.py):
  swings.json         one entry per cut: variant, source (GolfDB ids), frames, offset
  probabilities.u16   little-endian uint16, per cut frames x CLASSES: probability times SCALE, rounded
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "benchmark"))
from pack_phases import CLASSES, SCALE  # noqa: E402

VARIANTS = ["standing", "backswingOnly", "followThroughOnly", "reversed", "still", "twoSwings"]
STILL_FRAMES = 64


def cuts(features, events, previous):
    yield "standing", features[:events[2]]
    yield "backswingOnly", features[:events[4] + 1]
    yield "followThroughOnly", features[events[6] + 1:]
    yield "reversed", features[::-1]
    yield "still", np.repeat(features[events[1]:events[1] + 1], STILL_FRAMES, axis=0)
    if previous is not None:
        yield "twoSwings", np.concatenate([previous, features])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("golfdb", type=Path, help="GolfDB data dir with golfDB.pkl and videos_160/")
    ap.add_argument("--split", type=int, default=1)
    ap.add_argument("--limit", type=int)
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()

    import pandas as pd
    from golfdb_eval import load_model, read_frames, sequence_probabilities

    model = load_model("numpy")
    table = pd.read_pickle(a.golfdb / "golfDB.pkl")
    table = table[table["split"] == a.split]
    if a.limit:
        table = table.head(a.limit)
    entries, blocks, offset, skipped = [], [], 0, {v: 0 for v in VARIANTS}
    previous, previous_id = None, None
    for n, row in enumerate(table.itertuples(), 1):
        path = a.golfdb / "videos_160" / f"{row.id}.mp4"
        if not path.exists():
            raise SystemExit(f"{path} is missing")
        features = model.encode(read_frames(path))
        events = [int(e) - int(row.events[0]) for e in row.events]
        for variant, cut in cuts(features, events, previous):
            if len(cut) == 0:
                skipped[variant] += 1
                continue
            probs = sequence_probabilities(model, cut)
            if probs.shape != (len(cut), CLASSES) or not np.isfinite(probs).all():
                raise SystemExit(f"{row.id} {variant}: bad probabilities {probs.shape}")
            source = [previous_id, int(row.id)] if variant == "twoSwings" else [int(row.id)]
            entries.append({"variant": variant, "source": source, "frames": int(len(cut)), "offset": offset})
            blocks.append(np.rint(np.clip(probs, 0, 1) * SCALE).astype("<u2").reshape(-1))
            offset += blocks[-1].size
        previous, previous_id = features, int(row.id)
        if n % 25 == 0:
            print(f"{n}/{len(table)}", file=sys.stderr)

    a.out.mkdir(parents=True, exist_ok=True)
    np.concatenate(blocks).tofile(a.out / "probabilities.u16")
    manifest = {"version": 1, "split": a.split, "scale": SCALE, "classes": CLASSES, "variants": VARIANTS,
                "cuts": entries}
    (a.out / "swings.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    counts = {v: sum(1 for e in entries if e["variant"] == v) for v in VARIANTS}
    print(f"{len(entries)} cuts {counts}, empty cuts skipped {skipped}, {offset} values -> {a.out}")


if __name__ == "__main__":
    main()
