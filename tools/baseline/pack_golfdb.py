"""Packs the App-pipeline landmarks of the GolfDB down-the-line clips into the regression baseline's format.

  python3 tools/baseline/pack_golfdb.py <golfdb-app dir> <golfDB.pkl> --limit 400 --source-run <run id> --out baseline/golfdb400

Input: GolfDBAppPipelineTests JSON files (<name>.json: width, height, landmarks [frame][33][x, y, vis],
normalised, 4 decimals) and GolfDB's annotation table.

Output:
  swings.json    one entry per clip: name, id, youtube_id, player, slow, width, height, frames, events
                 (GolfDB's 10 frame numbers relative to the first: clip start, the 8 labelled events,
                 clip end; address, top and impact are entries 1, 4 and 6), offset (index of the clip's
                 first value in landmarks.i16)
  landmarks.i16  little-endian int16, per clip frames x 33 x 3: x and y times XY_SCALE, visibility times
                 VIS_SCALE; MISSING where the App returned no pose for the frame
"""
import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

XY_SCALE = 10000
VIS_SCALE = 1000
MISSING = -32768
JOINTS = 33


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("app_dir", type=Path)
    ap.add_argument("pkl", type=Path)
    ap.add_argument("--limit", type=int, default=400)
    ap.add_argument("--source-run", default="")
    ap.add_argument("--out", type=Path, required=True)
    a = ap.parse_args()

    table = pd.read_pickle(a.pkl)
    table = table[table["view"] == "down-the-line"].head(a.limit)
    swings, blocks, offset = [], [], 0
    for row in table.itertuples():
        name = f"golfdb_{row.id}"
        path = a.app_dir / f"{name}.json"
        if not path.exists():
            raise SystemExit(f"{path} is missing: the App run did not cover every clip")
        clip = json.loads(path.read_text(encoding="utf-8"))
        block = np.full((len(clip["landmarks"]), JOINTS, 3), MISSING, dtype=np.int64)
        for i, frame in enumerate(clip["landmarks"]):
            if len(frame) == JOINTS:
                values = np.asarray(frame, dtype=float)
                block[i, :, 0:2] = np.rint(values[:, 0:2] * XY_SCALE)
                block[i, :, 2] = np.rint(values[:, 2] * VIS_SCALE)
        if block.max() > 32767 or block[block != MISSING].min() < -32767:
            raise SystemExit(f"{name}: a coordinate does not fit in int16")
        events = [int(e) - int(row.events[0]) for e in row.events]
        swings.append({"name": name, "id": int(row.id), "youtube_id": str(row.youtube_id), "player": str(row.player),
                       "slow": int(row.slow), "width": clip["width"], "height": clip["height"],
                       "frames": int(block.shape[0]), "events": events, "offset": offset})
        blocks.append(block.astype("<i2").reshape(-1))
        offset += blocks[-1].size

    a.out.mkdir(parents=True, exist_ok=True)
    np.concatenate(blocks).tofile(a.out / "landmarks.i16")
    manifest = {"version": 1, "xyScale": XY_SCALE, "visibilityScale": VIS_SCALE, "missing": MISSING,
                "joints": JOINTS, "sourceRun": a.source_run, "swings": swings}
    (a.out / "swings.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(swings)} clips, {offset} values -> {a.out}")


if __name__ == "__main__":
    main()
