# SwingNet integration

Official source: https://github.com/wmcnally/golfdb
Checkpoint: swingnet_1800.pth.tar (https://drive.google.com/file/d/1MBIDwHSM8OKRbxS8YfyRLnUBAdt0nupW/view)

Attribution: William McNally, Kanav Vats, Tyler Pinto, Chris Dulhanty, John McPhee, Alexander Wong. “GolfDB: A Video Database for Golf Swing Sequencing”, CVPR Workshops 2019.

The upstream repository states CC BY-NC 4.0 for its code. These model sources are adapted from that repository, with CPU-safe initialization and no unnecessary MobileNet checkpoint load when loading the full trained SwingNet state. Commercial distribution requires resolving applicable code, model and data permissions; the application's own license does not replace upstream terms.
License: https://creativecommons.org/licenses/by-nc/4.0/

## Rebuild model packages

On macOS, install PyTorch, NumPy and coremltools in an isolated Python environment. Conversion was verified with Python 3.9, PyTorch 2.8.0, coremltools 9.0. Coremltools warns that Torch 2.8 is untested; numerical/video parity was checked separately.

Run from the repository root:

```sh
python tools/swingnet/convert.py --weights /path/to/swingnet_1800.pth.tar --output CoachMe/Resources
tools/setup-xcode-project.sh
```

`SwingNetEncoder.mlpackage` accepts one normalized RGB image [1,3,160,160] and returns [1,1280]. `SwingNetSequence.mlpackage` accepts [1,T,1280], 1 <= T <= 64, and returns [1,T,9] logits. Both use float32. A split model streams frames and caps the in-memory feature buffer at 64 frames, retaining the official chunk boundaries and bidirectional reset behavior. Never zero-pad the final chunk.

The app receives upright BGRA frames (up to 4096 pixels on the longest edge, avoiding a second resize through 720 pixels) from VideoAssetReader, applies aspect-fit and mean-colour padding, normalizes RGB channels, and performs local CPU inference. It uses frame presentation timestamps including nonzero clip offsets. It selects independent per-event probability maxima and maps events 0,2,3,4,5,7 to the six app phases. When the four interior phases are ordered, address/finish may be reselected on their appropriate side of the swing. Contradictory interior ordering yields no automatic markers, leaving manual marking available. No confidence threshold is applied: scores are not calibrated correctness probabilities. Manual edits set markedByCoach=true; automatic markers carry checkpoint and score in their note.

Inference runs locally. Existing records can request phase detection from the workbench; no automatic reanalysis occurs on opening a record.
