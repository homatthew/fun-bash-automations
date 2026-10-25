"""Allowance boundaries and billing/fallback accounting; no network or alerts."""
import runpy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

module = runpy.run_path(str(Path(__file__).parents[1] / 'bin/actions-budget-watch'))
thresholds = module['thresholds']


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

    def test_public_billing_excluded_missing_repo_conservative(self):
        fn = module['detailed_usage']
        report = {'usageItems': [dict(product='Actions', repositoryName=name, grossAmount=cost)
                                 for name, cost in [('public', 38), ('private', 6), ('deleted', 1)]]}
        repos = [[dict(name='public', private=False, owner={'login': 'example'})]]
        with patch.dict(fn.__globals__, api=lambda endpoint, **kw: repos if kw else report):
            self.assertEqual(fn('example', True, 2026, 10), 7)

    def test_fallback_rounds_each_attempt_and_caches(self):
        fn = module['estimate_usage']
        calls = []

        def api(endpoint, **kw):
            calls.append(endpoint)
            if '/user/repos?' in endpoint:
                return [[dict(id=1, full_name='example/private', private=True, owner={'login': 'example'})]]
            if '/attempts/' not in endpoint:
                return [{'workflow_runs': [dict(id=2, run_attempt=2)]}]
            job = dict(labels=['macos-15'], steps=[{}], status='completed',
                       started_at='2026-10-25T00:00:00Z', completed_at='2026-10-25T00:01:01Z')
            free = dict(job, labels=['self-hosted', 'macos'])
            blocked = dict(job, steps=[])
            return [{'jobs': [job, free, blocked]}]

        with tempfile.TemporaryDirectory() as directory, patch.dict(fn.__globals__, api=api):
            self.assertAlmostEqual(fn('example', False, 2026, 10, Path(directory)), 40 / 2000 * 12)
            calls.clear()
            fn('example', False, 2026, 10, Path(directory))
            self.assertFalse(any('/attempts/' in call for call in calls))


if __name__ == '__main__':
    unittest.main()
