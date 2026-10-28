# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Credential-free acceptance evidence schema, freshness and CLI regressions."""
import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from product_acceptance import IDENTITY_FIELDS, KINDS, report, sha, read_json

ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / 'docs/development/product_acceptance_manifest.json').read_text())
NOW = '2026-10-28T07:00:00Z'


def identity():
    return dict(sourceRevision='a' * 40, requirementSha256='b' * 64,
                inputSha256='c' * 64, configurationSha256='d' * 64,
                modelSha256='e' * 64, deviceSha256='f' * 64,
                sdkVersion='3.47.6', runtimeVersion='3.12.0', backend='mlx',
                host='macos', browserVersion='142.0')


def record():
    return dict(scenarioId='create-reopen', checkId='durable-records', target='macos',
                status='passed', observedAt=NOW, identity=identity(),
                manifestSha256=sha(SPEC), artifactSha256=['0' * 64])


def saved(*records):
    return dict(schemaVersion=1, records=list(records))


class AcceptanceTest(unittest.TestCase):
    def evaluate(self, *records, current=None):
        return report(SPEC, current or identity(), saved(*records), NOW)

    def test_manifest_references_exist_and_kinds_remain_distinct(self):
        kinds = set()
        for scenario in SPEC['scenarios']:
            for check in scenario['checks']:
                kinds.add(check['kind'])
                for ref in check['testReferences']:
                    self.assertTrue((ROOT / ref).is_file(), ref)
        self.assertEqual(kinds, set(KINDS))

    def test_missing_and_unavailable_never_pass(self):
        result = self.evaluate()
        self.assertEqual(result['claim'], 'saved-evidence-only')
        for cell in result['cells']:
            self.assertEqual(cell['status'], 'missing' if cell['target'] in
                             ('macos', 'web') else 'unavailable')
            self.assertFalse(cell['currentPass'])

    def test_fixture_pass_does_not_promote_other_kinds_targets_or_scenarios(self):
        result = self.evaluate(record())
        passing = [c for c in result['cells'] if c['currentPass']]
        self.assertEqual(len(passing), 1)
        self.assertEqual(passing[0]['kind'], 'fixture')
        self.assertEqual(passing[0]['savedEvidence'], record())
        self.assertEqual(json.loads(json.dumps(result)), result)

    def test_every_identity_change_invalidates_pass(self):
        for field in IDENTITY_FIELDS:
            with self.subTest(field=field):
                current = identity()
                current[field] = ('1' * (40 if field == 'sourceRevision' else 64)
                                  if field.endswith('Sha256') or field == 'sourceRevision'
                                  else 'linux' if field == 'host' else 'none'
                                  if field == 'backend' else '1.0')
                self.assertEqual(self.evaluate(record(), current=current)['cells'][0]['status'],
                                 'stale')

    def test_manifest_change_invalidates_saved_pass(self):
        r = record()
        r['manifestSha256'] = '1' * 64
        self.assertEqual(self.evaluate(r)['cells'][0]['status'], 'stale')

    def test_nonpassing_statuses_remain_nonpassing(self):
        for status in ('failed', 'skipped', 'unavailable'):
            r = record()
            r['status'] = status
            cell = self.evaluate(r)['cells'][0]
            self.assertEqual(cell['status'], status)
            self.assertFalse(cell['currentPass'])

    def test_rejects_future_and_invalid_times(self):
        for value in ('2027-01-01T00:00:00Z', '2026-02-30T00:00:00Z',
                      '2026-10-28', NOW + 'PRIVATE'):
            r = record()
            r['observedAt'] = value
            with self.assertRaises(ValueError):
                self.evaluate(r)

    def test_rejects_duplicates_unknown_ids_and_native_support_claim(self):
        with self.assertRaises(ValueError):
            self.evaluate(record(), record())
        for field, value in [('scenarioId', 'unknown'), ('checkId', 'unknown'),
                             ('target', 'ios'), ('status', 'verified')]:
            r = record()
            r[field] = value
            with self.assertRaises(ValueError):
                self.evaluate(r)

    def test_private_content_and_unbounded_artifacts_rejected(self):
        cases = []
        r = record()
        r['prompt'] = 'PRIVATE'
        cases.append(r)
        for field in IDENTITY_FIELDS:
            r = record()
            r['identity'][field] = '/Users/PRIVATE/token'
            cases.append(r)
        for value in (['/Users/PRIVATE'], ['0' * 64] * 17, 'PRIVATE', [{'token':'PRIVATE'}]):
            r = record()
            r['artifactSha256'] = value
            cases.append(r)
        for r in cases:
            with self.assertRaises(ValueError):
                self.evaluate(r)

    def test_unknown_versions_and_malformed_schema(self):
        for value in (True, 2, '1'):
            doc = saved()
            doc['schemaVersion'] = value
            with self.assertRaises(ValueError):
                report(SPEC, identity(), doc, NOW)
        for field in record():
            r = record()
            del r[field]
            with self.assertRaises(ValueError):
                self.evaluate(r)
        for field in ('scenarioId', 'checkId', 'target'):
            r = record()
            r[field] = []
            with self.assertRaises(ValueError):
                self.evaluate(r)

    def test_manifest_rejects_duplicates_paths_and_unknown_fields(self):
        for change in ('duplicate', 'path', 'field'):
            spec = copy.deepcopy(SPEC)
            if change == 'duplicate':
                spec['scenarios'].append(spec['scenarios'][0])
            elif change == 'path':
                spec['scenarios'][0]['checks'][0]['testReferences'] = ['../PRIVATE']
            else:
                spec['prompt'] = 'PRIVATE'
            with self.assertRaises(ValueError):
                report(spec, identity(), saved(), NOW)

    def test_cli_roundtrip_atomic_failure_and_sanitized_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            paths = [folder / name for name in ('manifest', 'identity', 'evidence')]
            for path, value in zip(paths, (SPEC, identity(), saved(record()))):
                path.write_text(json.dumps(value))
            output = folder / 'output'
            command = [sys.executable, '-B', str(ROOT / 'tools/product_acceptance.py')]
            for flag, path in zip(('--manifest', '--identity', '--evidence'), paths):
                command += [flag, str(path)]
            command += ['--output', str(output)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(read_json(output)['cells'][0]['status'], 'passed')
            before = output.read_bytes()
            paths[2].write_text('{"PRIVATE":')
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('PRIVATE', result.stderr)
            self.assertNotIn(directory, result.stderr)
            self.assertEqual(output.read_bytes(), before)
            # Refuse output aliasing an input, even when inputs are malformed.
            command[-1] = str(paths[0])
            result = subprocess.run(command, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(read_json(paths[0]), SPEC)

    def test_duplicate_json_keys_and_large_input_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'input'
            for data in ('{"schemaVersion":1,"schemaVersion":1}', ' ' * (1024*1024+1)):
                path.write_text(data)
                with self.assertRaises(ValueError):
                    read_json(path)


if __name__ == '__main__':
    unittest.main()
