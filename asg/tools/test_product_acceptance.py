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

    def test_plan_fixture_leaves_real_lifecycle_missing_on_each_target(self):
        for target in ('macos', 'web'):
            with self.subTest(target=target):
                fixture = dict(record(), scenarioId='approved-plan',
                               checkId='stale-plan-refusal', target=target)
                cells = [c for c in self.evaluate(fixture)['cells']
                         if c['scenarioId'] == 'approved-plan' and
                         c['target'] == target]
                self.assertEqual(len(cells), 2)
                self.assertTrue(next(c for c in cells
                                     if c['kind'] == 'fixture')['currentPass'])
                manual = next(c for c in cells if c['kind'] == 'manual')
                self.assertEqual(manual['checkId'], 'plan-lifecycle-interaction')
                self.assertEqual(manual['status'], 'missing')
                self.assertFalse(manual['currentPass'])

    def test_plan_lifecycle_requires_matching_saved_identity(self):
        manual = dict(record(), scenarioId='approved-plan',
                      checkId='plan-lifecycle-interaction')
        cells = self.evaluate(manual)['cells']
        matching = next(c for c in cells if c['scenarioId'] == 'approved-plan'
                        and c['target'] == 'macos' and c['kind'] == 'manual')
        self.assertTrue(matching['currentPass'])
        self.assertEqual(matching['savedEvidence'], manual)
        changed = dict(identity(), inputSha256='1' * 64)
        stale = next(c for c in self.evaluate(manual, current=changed)['cells']
                     if c['scenarioId'] == 'approved-plan' and
                     c['target'] == 'macos' and c['kind'] == 'manual')
        self.assertEqual(stale['status'], 'stale')
        self.assertFalse(stale['currentPass'])

    def test_pre_lifecycle_manifest_cannot_keep_fixture_current(self):
        previous = copy.deepcopy(SPEC)
        plan = next(s for s in previous['scenarios'] if s['id'] == 'approved-plan')
        plan['checks'] = [c for c in plan['checks']
                          if c['id'] != 'plan-lifecycle-interaction']
        fixture = dict(record(), scenarioId='approved-plan',
                       checkId='stale-plan-refusal', manifestSha256=sha(previous))
        cells = [c for c in self.evaluate(fixture)['cells']
                 if c['scenarioId'] == 'approved-plan' and c['target'] == 'macos']
        self.assertEqual({c['checkId']: c['status'] for c in cells},
                         {'stale-plan-refusal': 'stale',
                          'plan-lifecycle-interaction': 'missing'})
        self.assertFalse(any(c['currentPass'] for c in cells))

    def test_repair_inference_leaves_generated_and_manual_checks_missing(self):
        for target in ('macos', 'web'):
            with self.subTest(target=target):
                inference = dict(record(), scenarioId='bounded-repair',
                                 checkId='real-repair-rerun', target=target)
                cells = [c for c in self.evaluate(inference)['cells']
                         if c['scenarioId'] == 'bounded-repair' and
                         c['target'] == target]
                self.assertEqual({c['checkId']: (c['kind'], c['status']) for c in cells},
                                 {'real-repair-rerun': ('liveInference', 'passed'),
                                  'repair-confined-checks': ('generatedOutput', 'missing'),
                                  'repair-interaction': ('manual', 'missing')})
                self.assertEqual(sum(c['currentPass'] for c in cells), 1)

    def test_repair_output_pass_does_not_imply_interaction_and_becomes_stale(self):
        output = dict(record(), scenarioId='bounded-repair',
                      checkId='repair-confined-checks')
        cells = [c for c in self.evaluate(output)['cells']
                 if c['scenarioId'] == 'bounded-repair' and c['target'] == 'macos']
        self.assertEqual({c['checkId']: c['status'] for c in cells},
                         {'real-repair-rerun': 'missing',
                          'repair-confined-checks': 'passed',
                          'repair-interaction': 'missing'})
        manual = dict(output, checkId='repair-interaction')
        self.assertEqual(sum(c['currentPass'] for c in
                             self.evaluate(output, manual)['cells']), 2)
        for field in IDENTITY_FIELDS:
            with self.subTest(field=field):
                changed = identity()
                changed[field] = ('1' * (40 if field == 'sourceRevision' else 64)
                                  if field.endswith('Sha256') or field == 'sourceRevision'
                                  else 'linux' if field == 'host' else 'none'
                                  if field == 'backend' else '1.0')
                stale = [c for c in self.evaluate(output, manual, current=changed)['cells']
                         if c['savedEvidence']]
                self.assertEqual([c['status'] for c in stale], ['stale', 'stale'])
                self.assertFalse(any(c['currentPass'] for c in stale))

    def test_pre_repair_split_manifest_cannot_keep_inference_current(self):
        previous = copy.deepcopy(SPEC)
        repair = next(s for s in previous['scenarios'] if s['id'] == 'bounded-repair')
        repair['checks'] = [c for c in repair['checks'] if c['id'] == 'real-repair-rerun']
        inference = dict(record(), scenarioId='bounded-repair',
                         checkId='real-repair-rerun', manifestSha256=sha(previous))
        cells = [c for c in self.evaluate(inference)['cells']
                 if c['scenarioId'] == 'bounded-repair' and c['target'] == 'macos']
        self.assertEqual({c['checkId']: c['status'] for c in cells},
                         {'real-repair-rerun': 'stale',
                          'repair-confined-checks': 'missing',
                          'repair-interaction': 'missing'})
        self.assertFalse(any(c['currentPass'] for c in cells))

    def test_stop_deadline_and_combined_observations_do_not_imply_each_other(self):
        check_ids = ('stop-and-timeout', 'stop-interaction', 'deadline-interaction')
        for target in ('macos', 'web'):
            for check_id in check_ids:
                with self.subTest(target=target, check_id=check_id):
                    observation = dict(record(), scenarioId='stop-preservation',
                                       checkId=check_id, target=target)
                    cells = [c for c in self.evaluate(observation)['cells']
                             if c['scenarioId'] == 'stop-preservation' and
                             c['target'] == target]
                    self.assertEqual({c['checkId']: c['status'] for c in cells},
                                     {key: 'passed' if key == check_id else 'missing'
                                      for key in check_ids})
                    self.assertEqual(sum(c['currentPass'] for c in
                                         self.evaluate(observation)['cells']), 1)

    def test_stop_deadline_observations_require_exact_current_identity(self):
        observations = [dict(record(), scenarioId='stop-preservation', checkId=key)
                        for key in ('stop-interaction', 'deadline-interaction')]
        for field in IDENTITY_FIELDS:
            with self.subTest(field=field):
                current = identity()
                current[field] = ('1' * (40 if field == 'sourceRevision' else 64)
                                  if field.endswith('Sha256') or field == 'sourceRevision'
                                  else 'linux' if field == 'host' else 'none'
                                  if field == 'backend' else '1.0')
                cells = [c for c in self.evaluate(*observations, current=current)['cells']
                         if c['savedEvidence']]
                self.assertEqual([c['status'] for c in cells], ['stale', 'stale'])
                self.assertFalse(any(c['currentPass'] for c in cells))

    def test_historical_combined_stop_manifest_is_readable_but_stale(self):
        previous = copy.deepcopy(SPEC)
        scenario = next(s for s in previous['scenarios']
                        if s['id'] == 'stop-preservation')
        scenario['checks'] = [c for c in scenario['checks']
                              if c['id'] == 'stop-and-timeout']
        old = dict(record(), scenarioId='stop-preservation',
                   checkId='stop-and-timeout', manifestSha256=sha(previous))
        cells = [c for c in self.evaluate(old)['cells']
                 if c['scenarioId'] == 'stop-preservation' and c['target'] == 'macos']
        self.assertEqual({c['checkId']: c['status'] for c in cells},
                         {'stop-and-timeout': 'stale', 'stop-interaction': 'missing',
                          'deadline-interaction': 'missing'})
        self.assertFalse(any(c['currentPass'] for c in cells))

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


class ProvenanceImportTest(unittest.TestCase):
    def provenance(self, scenario='reviewed-candidate'):
        return dict(schemaVersion=1, scope='f10-saved-snapshot-link-only',
                    scenarioId=scenario, sourceRevision='a' * 40,
                    requirementSha256='b' * 64, inputSha256='c' * 64,
                    generatedSourceSha256='1' * 64, approvalSha256='2' * 64,
                    savedRunSha256='3' * 64)

    def assemble(self, provenance=None, **kwargs):
        from import_acceptance_provenance import import_observation
        options = dict(check_id='model-proposal', target='macos', status='passed',
                       observed_at=NOW, now=NOW)
        options.update(kwargs)
        return import_observation(SPEC, identity(), saved(),
                                  self.provenance() if provenance is None else provenance,
                                  **options)

    def test_supported_mappings_roundtrip_without_mutation_or_pass_inference(self):
        from import_acceptance_provenance import CHECKS
        for scenario, checks in CHECKS.items():
            for check in checks:
                for status in ('passed', 'failed', 'skipped', 'unavailable'):
                    with self.subTest(scenario=scenario, check=check, status=status):
                        p = self.provenance(scenario)
                        before = copy.deepcopy(p)
                        result = self.assemble(p, check_id=check, status=status)
                        self.assertEqual(p, before)
                        r = result['records'][0]
                        self.assertEqual(r['artifactSha256'],
                                         ['1' * 64, '2' * 64, '3' * 64, sha(p)])
                        matrix = report(SPEC, identity(), result, NOW)
                        cells = [c for c in matrix['cells'] if c['savedEvidence']]
                        self.assertEqual(len(cells), 1)
                        self.assertEqual(cells[0]['status'], status)
                        self.assertEqual(cells[0]['currentPass'], status == 'passed')
                        changed = identity()
                        changed['configurationSha256'] = '4' * 64
                        stale = report(SPEC, changed, result, NOW)
                        self.assertFalse(any(c['currentPass'] for c in stale['cells']))

    def test_repair_output_import_leaves_manual_missing_and_refuses_manual_mapping(self):
        p = self.provenance('bounded-repair')
        evidence = self.assemble(p, check_id='repair-confined-checks')
        cells = [c for c in report(SPEC, identity(), evidence, NOW)['cells']
                 if c['scenarioId'] == 'bounded-repair' and c['target'] == 'macos']
        self.assertEqual({c['checkId']: c['status'] for c in cells},
                         {'real-repair-rerun': 'missing',
                          'repair-confined-checks': 'passed',
                          'repair-interaction': 'missing'})
        with self.assertRaises(ValueError):
            self.assemble(p, check_id='repair-interaction')

    def test_rejects_missing_extra_private_and_mismatched_provenance(self):
        for field in self.provenance():
            p = self.provenance()
            del p[field]
            with self.assertRaises(ValueError):
                self.assemble(p)
        for field in self.provenance():
            p = self.provenance()
            p[field] = '/Users/PRIVATE/prompt'
            with self.assertRaises(ValueError):
                self.assemble(p)
        for field in ('sourceRevision', 'requirementSha256', 'inputSha256'):
            p = self.provenance()
            p[field] = '9' * len(p[field])
            with self.assertRaises(ValueError):
                self.assemble(p)
        for field, value in (('schemaVersion', True), ('scenarioId', []),
                             ('prompt', 'PRIVATE')):
            p = self.provenance()
            p[field] = value
            with self.assertRaises(ValueError):
                self.assemble(p)

    def test_rejects_unrelated_checks_invalid_status_time_and_duplicates(self):
        from import_acceptance_provenance import import_observation
        for options in (dict(check_id='served-interaction'), dict(check_id=[]),
                        dict(target='ios'), dict(status='verified'), dict(status=None),
                        dict(observed_at='2027-01-01T00:00:00Z'),
                        dict(observed_at='2026-02-30T00:00:00Z')):
            with self.assertRaises(ValueError):
                self.assemble(**options)
        first = self.assemble()
        before = copy.deepcopy(first)
        with self.assertRaises(ValueError):
            import_observation(SPEC, identity(), first, self.provenance(),
                               check_id='model-proposal', target='macos',
                               status='passed', observed_at=NOW, now=NOW)
        self.assertEqual(first, before)

    def test_cli_roundtrip_atomic_error_privacy_and_all_input_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            paths = [folder / name for name in
                     ('manifest', 'identity', 'evidence', 'provenance')]
            values = (SPEC, identity(), saved(), self.provenance())
            for path, value in zip(paths, values):
                path.write_text(json.dumps(value))
            output = folder / 'output'
            command = [sys.executable, '-B',
                       str(ROOT / 'tools/import_acceptance_provenance.py')]
            for flag, path in zip(('--manifest', '--identity', '--evidence',
                                   '--provenance'), paths):
                command += [flag, str(path)]
            command += ['--check', 'model-proposal', '--target', 'macos',
                        '--status', 'skipped', '--observed-at', NOW,
                        '--output', str(output)]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(read_json(output)['records'][0]['status'], 'skipped')
            before = output.read_bytes()
            paths[-1].write_text('{"PRIVATE":')
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('PRIVATE', result.stderr)
            self.assertNotIn(directory, result.stderr)
            self.assertEqual(output.read_bytes(), before)
            for path in paths:
                command[-1] = str(path)
                original = path.read_bytes()
                result = subprocess.run(command, capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(path.read_bytes(), original)
            self.assertEqual(sorted(p.name for p in folder.iterdir()),
                             ['evidence', 'identity', 'manifest', 'output', 'provenance'])


if __name__ == '__main__':
    unittest.main()
