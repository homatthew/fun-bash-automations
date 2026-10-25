"""Threshold boundaries and deduplication; no network or notifications."""
import runpy
import unittest
from pathlib import Path

thresholds = runpy.run_path(str(Path(__file__).parents[1] / 'bin/actions-budget-watch'))['thresholds']


class BudgetThresholds(unittest.TestCase):
    def test_boundaries_and_deduplication(self):
        self.assertEqual(thresholds(999, 2000, []), [])
        self.assertEqual(thresholds(1000, 2000, []), [50])
        self.assertEqual(thresholds(1600, 2000, [50]), [80])
        self.assertEqual(thresholds(2000, 2000, [50, 80]), [])
        self.assertEqual(thresholds(2000, 2000, []), [50, 80])

    def test_unavailable_allowance_is_not_zero_usage(self):
        with self.assertRaises(ValueError):
            thresholds(0, 0, [])


if __name__ == '__main__':
    unittest.main()
