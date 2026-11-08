"""Python readers must turn iPhone portrait clips upright, like the App (RotatedVideoTests.swift).

  python tools/e2e/test_rotation.py

Fixture CoachMeTests/Fixtures/rotated_portrait.mov: 90x160 portrait picture (blue, red square at the
top-left) stored turned 90 degrees with display rotation -90, like a real iPhone file.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "faults"))
sys.path.insert(0, str(ROOT / "tools" / "benchmark"))
sys.path.insert(0, str(ROOT / "tools" / "e2e"))
FIXTURE = ROOT / "CoachMeTests" / "Fixtures" / "rotated_portrait.mov"


def upright(img) -> bool:
    h, w = img.shape[:2]
    b, g, r = (int(v) for v in img[10, 10])
    b2 = int(img[h - 10, w - 10][0])
    return (h, w) == (160, 90) and r > 150 and b < 100 and b2 > 150


class RotationTest(unittest.TestCase):
    def test_run_path_reader(self):
        from run_path import read_video
        frames, _ = read_video(FIXTURE)
        self.assertTrue(upright(frames[0]), frames[0].shape)

    def test_e2e_reader(self):
        from python_layers import decode
        frames, _, _ = decode(FIXTURE)
        self.assertTrue(upright(frames[0]), frames[0].shape)

    def test_swingnet_reader_keeps_portrait_aspect(self):
        import numpy as np
        from golfdb_eval import MEAN, STD, read_frames
        x = read_frames(FIXTURE)[0]  # [3,160,160], portrait = padded left/right, picture 90 wide
        rgb = (x * STD + MEAN).transpose(1, 2, 0)
        # padding columns at the far left; red square right after it at the top
        self.assertLess(abs(rgb[80, 2] - np.array([0.485, 0.456, 0.406])).max(), 0.02)
        self.assertGreater(rgb[10, 40, 0], 0.6)
        self.assertLess(rgb[10, 40, 2], 0.4)


if __name__ == "__main__":
    unittest.main()
