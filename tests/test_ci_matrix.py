#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ci_matrix', str(ROOT / 'tools/ci-matrix.py'))
ci_matrix = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci_matrix)


class WorkflowTargets(unittest.TestCase):
    def test_all_uses_manifest_targets_in_stable_order(self):
        expected = sorted(str(p.parent.relative_to(ROOT / 'targets'))
                          for p in (ROOT / 'targets').glob('*/*/manifest.txt'))
        self.assertEqual(ci_matrix.matrix('all'), {'target': expected})

    def test_select_one(self):
        self.assertEqual(ci_matrix.matrix('ubuntu-24.04/6.8.0-139'),
                         {'target': ['ubuntu-24.04/6.8.0-139']})

    def test_unknown_and_traversal_are_rejected(self):
        for value in ('', '../../etc', 'unknown/1.0', 'all; echo bad'):
            with self.assertRaises(ValueError):
                ci_matrix.matrix(value)

    def test_empty_catalog_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(ValueError):
                ci_matrix.matrix('all', Path(directory))


if __name__ == '__main__':
    unittest.main()
