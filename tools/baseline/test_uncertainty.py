"""The per-unit values behind the regression intervals must add up to the gated metrics in each committed snapshot.

  python3 tools/baseline/test_uncertainty.py
"""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools" / "baseline"))
import regress  # noqa: E402
import regress_keyframes  # noqa: E402
import regress_phases  # noqa: E402
import uncertainty  # noqa: E402


def snapshot(module):
    return json.loads(module.EXPECTED.read_text(encoding="utf-8"))


class UnitsMatchMetrics(unittest.TestCase):
    def test_pairs(self):
        expected = snapshot(regress)
        units = regress.units(expected["clips"])
        self.assertEqual(len(units), expected["metrics"]["pairs"])
        self.assertEqual(sum(units.values()), expected["metrics"]["pairsAgreeing"])

    def test_phases(self):
        expected = snapshot(regress_phases)
        units = regress_phases.units(expected["clips"])
        self.assertEqual(len(units), expected["metrics"]["clips"])
        self.assertAlmostEqual(sum(units.values()) / len(units), expected["metrics"]["phaseAccuracy"], places=4)

    def test_motion_phases(self):
        expected = snapshot(regress_phases)
        units = regress_phases.units(expected["clips"], regress_phases.MOTION)
        self.assertEqual([regress_phases.PHASES[i] for i in regress_phases.MOTION],
                         ["takeaway", "midBackswing", "top", "midDownswing", "impact"])
        self.assertAlmostEqual(sum(units.values()) / len(units), expected["metrics"]["motionPhaseAccuracy"], places=4)

    def test_trading_a_motion_phase_for_address_fails_the_gate(self):
        before = snapshot(regress_phases)["metrics"]
        traded = {**before, "motionPhaseAccuracy": before["motionPhaseAccuracy"] - 0.0001}
        self.assertEqual(regress_phases.lowered(before, traded), ["motionPhaseAccuracy"])
        self.assertEqual(regress_phases.lowered(before, before), [])

    def test_keyframes(self):
        expected = snapshot(regress_keyframes)
        units = regress_keyframes.units(expected["clips"])
        self.assertEqual(len(units), expected["metrics"]["clips"])
        self.assertEqual(sum(units.values()), expected["metrics"]["agreeing"])


class Intervals(unittest.TestCase):
    def test_constant_values_have_no_spread(self):
        self.assertEqual(uncertainty.interval([1.0] * 20), (1.0, 1.0))

    def test_reproducible(self):
        values = [1.0] * 150 + [0.0] * 12
        self.assertEqual(uncertainty.interval(values), uncertainty.interval(values))

    def test_interval_contains_mean(self):
        values = [1.0] * 150 + [0.0] * 12
        lo, hi = uncertainty.interval(values)
        self.assertLess(lo, 150 / 162)
        self.assertGreater(hi, 150 / 162)

    def test_paired_counts_changed_units(self):
        before = {k: 0.0 for k in range(100)}
        after = {**before, 0: 1.0, 1: 1.0, 2: -1.0}
        p = uncertainty.paired(before, after)
        self.assertEqual((p["units"], p["better"], p["worse"]), (100, 2, 1))
        self.assertAlmostEqual(p["change"], 0.01)
        self.assertLessEqual(p["low"], 0.0)

    def test_paired_ignores_units_on_one_side(self):
        p = uncertainty.paired({"a": 0.0, "b": 1.0}, {"a": 1.0, "c": 0.0})
        self.assertEqual((p["units"], p["better"]), (1, 1))


if __name__ == "__main__":
    unittest.main()
