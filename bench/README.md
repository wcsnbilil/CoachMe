# winrun scripts recovered from the old PC session (2026-11-10)

These were rebuilt from the session record of what was written to `C:\Users\49907\coachme-bench\winrun\` on the old Desktop.
They are for redeploying on computer B (Hank). All Python files parse; none has been re-run on B yet.

## Paths

- Every script hard-codes `C:\Users\49907\coachme-bench`. Change that if B uses a different user or folder.
- They expect the repo checkout at `coachme-bench\coachme` (branch `claude/e2e-parity`).
- They expect the venv at `coachme-bench\venv`.
- They expect `coachme\sam2_b.pt`.

## Not recovered (rewrite on B)

**`watcher.ps1`**
- Loops every 5 s.
- If a `VALORANT` / `VALORANT-Win64-Shipping` process is running, or a `PAUSE` file exists in coachme-bench, it kills the jobs: any python.exe whose command line contains `coachme-bench`, plus the `jobs.ps1` powershell.
- Otherwise, if nothing is running and there is no `jobs.done` / `jobs.failed`, it starts `winrun\jobs.ps1` hidden.
- It uses the mutex `Global\CoachMeWatcher` and logs to `watcher.log`.

**`jobs.ps1`**
- Resumable steps, each marked by a `step_<name>.done` file.
- Steps relevant on B:
  1. Start `collect2.ps1` hidden (footage search / meta / select / download).
  2. `seg_lists.py`, then 4 parallel `tools\club\hd_pipeline.py hd_swings\seg_list{i}.txt --out hd_swings\seg_p{i}`.
  3. Repeat the segmentation after collect2 finishes.
- It ends by writing `jobs.done`.

**Earlier helpers**
- `am_*.py`, `w3d*.py`, `skel_feas.py`, `fbhd_*.txt`, `hd_part*.txt` are not needed for the current plan.

## What each script is

- **Footage:** `hd_collect.py` (search | meta | select | download | report, into `hd_swings\`), `collect2.ps1`, `seg_lists.py`.
- **Club:**
  - `club_track2.py` patches the repo's `tools\club\club_track.py` with a radial address-shaft finder and cropped SAM 2 with fallbacks.
  - `club4.py` produces 4 club points per frame; it is a first version, tested on 2 swings only.
  - `club_dbg.py` and `club_view.py` are debug helpers.
- **Target line:** `target_line.py` (final version, see `../target-line/README.md`), `test_target_stick.py`, `target_batch.py`.
- **Skeleton benchmark:**
  - `bench_select.py` picks about 300 frames.
  - `bench_models.py` runs RTMW via rtmlib and ViTPose-H via transformers, and takes MediaPipe from the cached landmarks.
  - `bench_sheet.py` makes the grid sheet for labelling.
  - `bench_framesjs.py` plus `pose_bench\label.html` are the local click-labelling page.
- **Niko's clips:** `niko_*.py`, `impact_zone.py`, `impact_geom*.py`, `late_phase.py`. These are local-only inputs; the clips themselves never leave Niko's PC.

## Python environment

- Python 3.11.
- torch 2.6 cu124.
- ultralytics, mediapipe, opencv-contrib-python.
- rtmlib, installed with `--no-deps`.
- onnxruntime-gpu, transformers, scipy, yt-dlp.

## Known issues

- `hd_pipeline.segment()` is tuned for real-time video and looks unreliable on slow-motion uploads (0 or 20 swings per video). Spot-check it before trusting the counts.
- `club4.py`: SAM sometimes tracks trousers instead of the club. A thin-shape filter was added, but it is not yet verified.
