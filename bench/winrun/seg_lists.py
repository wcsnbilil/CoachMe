"""Split hd_swings\\video into 4 stable parts (by crc32 of the file stem) for hd_pipeline runs."""
import zlib
from pathlib import Path

VID = Path(r"C:\Users\49907\coachme-bench\hd_swings\video")
OUT = Path(r"C:\Users\49907\coachme-bench\hd_swings")
parts = [[], [], [], []]
for p in sorted(VID.iterdir()):
    if p.suffix.lower() in (".mp4", ".webm", ".mkv", ".mov") and p.stat().st_size > 100_000:
        parts[zlib.crc32(p.stem.encode()) % 4].append(str(p))
for i, ps in enumerate(parts):
    (OUT / f"seg_list{i}.txt").write_text("\n".join(ps), encoding="utf-8")
print([len(p) for p in parts])
