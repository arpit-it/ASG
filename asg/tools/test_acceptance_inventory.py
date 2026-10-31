# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Inventory trust-boundary and preservation regressions."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from acceptance_inventory import inventory, CLAIM
from product_acceptance import read_json

ROOT = Path(__file__).resolve().parents[1]
NOW = '2026-11-01T00:00:00Z'


class InventoryTest(unittest.TestCase):
    def fixture(self, folder):
        app = Path(folder) / 'app'
        relative = 'docs/development/acceptance/2026-10-30-native-fixture-baseline'
        shutil.copytree(ROOT / relative, app / relative)
        shutil.copyfile(ROOT / 'docs/development/product_acceptance_manifest.json',
                        app / 'docs/development/product_acceptance_manifest.json')
        (app / 'lib').mkdir()
        (app / 'lib/new.dart').write_text('new runtime')
        return app, relative

    def test_separate_identities_determinism_and_no_promotion(self):
        paths = sorted(p.parent.relative_to(ROOT).as_posix() for p in
                       (ROOT / 'docs/development/acceptance').glob('*/report.json'))
        before = {p: (ROOT / p / 'report.json').read_bytes() for p in paths}
        value = inventory(ROOT, paths, NOW)
        self.assertEqual(value, inventory(ROOT, list(reversed(paths)), '2026-11-02T00:00:00Z'))
        self.assertEqual(value['claim'], CLAIM)
        self.assertEqual(len(value['configuredCells']), 29)
        self.assertTrue(all(c['observationDirectories'] for c in value['configuredCells']))
        self.assertGreater(len({r['identity']['sourceRevision'] for r in value['reports']}), 1)
        self.assertNotIn('currentPass', json.dumps(value))
        self.assertEqual(before, {p: (ROOT / p / 'report.json').read_bytes() for p in paths})

    def test_tampered_rendering_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app, relative = self.fixture(folder)
            path = app / relative / 'report.json'
            value = read_json(path)
            next(c for c in value['cells'] if c['savedEvidence'])['currentPass'] = False
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, 'Inconsistent saved status'):
                inventory(app, [relative], NOW)

    def test_duplicate_escape_and_symlink_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app, relative = self.fixture(folder)
            for paths in ([relative, relative], [relative + '/../escape'],
                          [relative + '/./'], ['/private/tmp']):
                with self.subTest(paths=paths), self.assertRaises(ValueError):
                    inventory(app, paths, NOW)
            link = app / 'docs/development/acceptance/link'
            link.symlink_to(app / relative, target_is_directory=True)
            with self.assertRaisesRegex(ValueError, 'Symlink'):
                inventory(app, ['docs/development/acceptance/link'], NOW)

    def test_source_comparison_exposes_missing_and_unrecorded_files(self):
        with tempfile.TemporaryDirectory() as folder:
            app, relative = self.fixture(folder)
            value = inventory(app, [relative], NOW)['reports'][0]['sourceComparison']
            self.assertEqual(value['unrecordedRuntimeFiles'], ['lib/new.dart'])
            self.assertTrue(value['absentRecordedFiles'])
            (app / relative / 'source-manifest.json').unlink()
            value = inventory(app, [relative], NOW)['reports'][0]['sourceComparison']
            self.assertEqual(value, {'status': 'not-recorded'})

    def test_cli_atomic_failure_privacy_and_input_preservation(self):
        with tempfile.TemporaryDirectory() as folder:
            app, relative = self.fixture(folder)
            output = Path(folder) / 'output.json'
            output.write_text('retained')
            evidence = app / relative / 'evidence.json'
            evidence.write_text('{"schemaVersion":1,"schemaVersion":1,"records":[]}')
            args = [sys.executable, '-B', str(ROOT / 'tools/acceptance_inventory.py'),
                    '--app', str(app), '--output', str(output)]
            result = subprocess.run(args, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(output.read_text(), 'retained')
            self.assertNotIn(str(app).encode(), result.stderr)
            original = evidence.read_bytes()
            args[-1] = str(evidence)
            self.assertEqual(subprocess.run(args, capture_output=True).returncode, 2)
            self.assertEqual(evidence.read_bytes(), original)
            self.assertEqual(sorted(p.name for p in Path(folder).iterdir()), ['app', 'output.json'])

    def test_incomplete_groups_and_forged_identity_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            app, relative = self.fixture(folder)
            path = app / relative / 'report.json'
            original = read_json(path)
            for mutate in (lambda d: d['cells'].pop(),
                           lambda d: d['identity'].update(sourceRevision='0' * 40)):
                value = json.loads(json.dumps(original))
                mutate(value)
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    inventory(app, [relative], NOW)

    def test_normalized_source_alias_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            app, relative = self.fixture(folder)
            path = app / relative / 'source-manifest.json'
            path.write_text(json.dumps({'lib/new.dart': '0' * 64, 'asg/lib/new.dart': '0' * 64}))
            with self.assertRaisesRegex(ValueError, 'Duplicate normalized'):
                inventory(app, [relative], NOW)

    def test_checked_in_inventory_matches_regeneration(self):
        paths = sorted(p.parent.relative_to(ROOT).as_posix() for p in
                       (ROOT / 'docs/development/acceptance').glob('*/report.json'))
        self.assertEqual(read_json(ROOT / 'docs/development/acceptance_inventory.json'),
                         inventory(ROOT, paths, NOW))

    def test_empty_corpus_still_validates_manifest_before_output_replacement(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'app'
            spec_path = app / 'docs/development/product_acceptance_manifest.json'
            spec_path.parent.mkdir(parents=True)
            (app / 'lib').mkdir()
            output = Path(folder) / 'output.json'
            for value in (dict(read_json(ROOT / 'docs/development/product_acceptance_manifest.json'),
                               unexpected='invalid'), {'schemaVersion': 1, 'scenarios': None}):
                spec_path.write_text(json.dumps(value))
                output.write_text('retained')
                result = subprocess.run([sys.executable, '-B', str(ROOT / 'tools/acceptance_inventory.py'),
                                         '--app', str(app), '--output', str(output)], capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(output.read_text(), 'retained')
                self.assertNotIn(str(app).encode(), result.stderr)


if __name__ == '__main__':
    unittest.main()
