#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Disposable Git worktrees and real subprocess contention for local ownership."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).with_name('development_coordinator.py')
spec = importlib.util.spec_from_file_location('development_coordinator', SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'repo'
        self.repo.mkdir()
        self.git(self.repo, 'init', '-q')
        self.git(self.repo, 'config', 'user.name', 'Test')
        self.git(self.repo, 'config', 'user.email', 'test@example.invalid')
        (self.repo / 'baseline').write_text('baseline')
        self.git(self.repo, 'add', 'baseline')
        self.git(self.repo, 'commit', '-qm', 'baseline')
        self.base = self.git(self.repo, 'rev-parse', 'HEAD')
        self.git(self.repo, 'update-ref', 'refs/remotes/origin/main', self.base)
        self.worktrees = []
        for index in range(3):
            worktree = self.root / ('writer' + str(index))
            self.git(self.repo, 'worktree', 'add', '-q', '--detach', str(worktree))
            self.worktrees.append(worktree)
        self.coords = [module.Coordinator(p) for p in self.worktrees]

    @staticmethod
    def git(repo, *args):
        return subprocess.check_output(['git', '-C', str(repo), *args], text=True,
                                       stderr=subprocess.PIPE).strip()

    def value(self, task='510-a', paths=None):
        return {'task': task, 'requirement': 'F56', 'outcome': 'A complete tested user outcome.',
                'dependencies': [], 'scope': paths or ['asg/tools/a.py'],
                'acceptance': ['Actual end-to-end result passes.'],
                'failure_cases': ['Interrupted work retains prior state.'],
                'validation': ['Run representative failure/recovery checks.']}

    def claim(self, index=0, task='510-a', paths=None):
        return self.coords[index].claim(self.value(task, paths), 'writer-' + str(index), 900)['token']

    def cli(self, index, *args):
        return subprocess.run([sys.executable, '-B', str(SCRIPT), '--repo',
                               str(self.worktrees[index]), *args], text=True,
                              capture_output=True, timeout=15)

    def expiry(self, task):
        with sqlite3.connect(self.coords[0].path) as db:
            db.execute('UPDATE claims SET expires=0 WHERE task=?', (task,))

    def record(self, token, kind, actor='reviewer', head=None, base=None, merge_sha=None):
        return self.coords[0].record('510-a', token, kind, head or self.base,
                                     base or self.base, actor, 'https://example.invalid/evidence', merge_sha)

    def test_real_subprocess_race_grants_only_one_same_task(self):
        contract = self.root / 'contract.json'
        contract.write_text(json.dumps(self.value()))
        processes = [subprocess.Popen([sys.executable, '-B', str(SCRIPT), '--repo', str(path),
                                      'claim', '--contract', str(contract), '--owner', 'run-' + str(i)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                     for i, path in enumerate(self.worktrees[:2])]
        results = [process.communicate(timeout=15) for process in processes]
        self.assertEqual(sorted(p.returncode for p in processes), [0, 2])
        winner = next(json.loads(out) for process, (out, _) in zip(processes, results) if process.returncode == 0)
        self.assertEqual(len(winner['token']), 64)
        self.assertEqual(len(self.coords[0].status()['claims']), 1)
        status = self.coords[0].status()
        self.assertNotIn(winner['token'], json.dumps(status))
        self.assertEqual(status['claims'][0]['scope'], ['asg/tools/a.py'])
        self.assertEqual(status['claims'][0]['requirement'], 'F56')

    def test_real_subprocess_race_enforces_two_writer_limit(self):
        processes = []
        for index, worktree in enumerate(self.worktrees):
            source = self.root / ('contract-' + str(index) + '.json')
            source.write_text(json.dumps(self.value('510-' + str(index), ['track' + str(index)])))
            processes.append(subprocess.Popen(
                [sys.executable, '-B', str(SCRIPT), '--repo', str(worktree), 'claim',
                 '--contract', str(source), '--owner', 'run-' + str(index)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
        for process in processes:
            process.communicate(timeout=15)
        self.assertEqual(sorted(p.returncode for p in processes), [0, 0, 2])
        self.assertEqual(len(self.coords[0].status()['claims']), 2)

    def test_prefix_conflicts_two_slots_and_distinct_worktrees(self):
        token = self.claim(paths=['asg/lib'])
        with self.assertRaises(module.CoordinationError):
            self.claim(1, '510-b', ['asg/lib/models/a.dart'])
        with self.assertRaises(module.CoordinationError):
            self.claim(0, '510-b', ['asg/tools'])
        with self.assertRaises(module.CoordinationError):
            self.claim(1, '510-case', ['ASG/LIB/a.dart'])
        self.claim(1, '510-b', ['asg/library'])  # Segment, not lexical prefix.
        with self.assertRaises(module.CoordinationError):
            self.claim(2, '510-c', ['README.md'])
        self.coords[0].release('510-a', token)
        self.claim(2, '510-c', ['README.md'])

    def test_expired_claim_blocks_until_explicit_reconciliation(self):
        token = self.claim(paths=['asg/lib'])
        self.expiry('510-a')
        with self.assertRaises(module.CoordinationError):
            self.coords[0].renew('510-a', token, 900)
        with self.assertRaises(module.CoordinationError):
            self.claim(1, '510-b', ['asg/lib'])
        self.assertTrue(self.coords[0].status()['claims'][0]['expired'])
        self.coords[1].reconcile('510-a', 'Worker stopped; remote effects settled at verified ref.')
        self.claim(1, '510-b', ['asg/lib'])
        with self.assertRaises(module.CoordinationError):
            self.coords[0].release('510-a', token)

    def test_live_reconciliation_and_wrong_owner_fail(self):
        token = self.claim()
        for operation in [lambda: self.coords[0].release('510-a', 'wrong'),
                          lambda: self.coords[1].renew('510-a', token, 900),
                          lambda: self.coords[1].reconcile('510-a', 'not expired'),
                          lambda: self.coords[0].renew('510-a', token, 1)]:
            with self.assertRaises(module.CoordinationError):
                operation()
        self.coords[0].renew('510-a', token, 3600)

    def test_invalid_contracts_never_claim(self):
        invalid = [dict(self.value(), extra=True), dict(self.value(), requirement='x'),
                   dict(self.value(), validation=[]), dict(self.value(), scope=['../escape']),
                   dict(self.value(), scope=['asg/lib', 'asg/lib/a']),
                   dict(self.value(), scope=['asg/*']), dict(self.value(), scope=['.git/config']), dict(self.value(), scope=['.GIT/config']),
                   dict(self.value(), scope=['asg//a']), dict(self.value(), scope=['asg/./a']),
                   dict(self.value(), dependencies=[{'task': '510-a', 'evidence': 'self'}])]
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(module.CoordinationError):
                self.coords[0].claim(value, 'writer', 900)
        self.assertEqual(self.coords[0].status()['claims'], [])

    def test_dirty_symlink_and_subdirectory_refused(self):
        path = self.worktrees[0] / 'dirty'
        path.write_text('private')
        with self.assertRaises(module.CoordinationError):
            self.claim()
        path.unlink()
        (self.worktrees[0] / 'alias').symlink_to(self.root)
        self.git(self.worktrees[0], 'add', 'alias')
        self.git(self.worktrees[0], 'commit', '-qm', 'symlink')
        with self.assertRaises(module.CoordinationError):
            self.claim(paths=['alias/output'])
        with self.assertRaises(module.CoordinationError):
            module.Coordinator(self.worktrees[0] / '.git')

    def test_dependencies_cannot_start_while_prerequisite_active(self):
        token = self.claim()
        value = self.value('510-b', ['README.md'])
        value['dependencies'] = [{'task': '510-a', 'evidence': 'not enough while active'}]
        with self.assertRaises(module.CoordinationError):
            self.coords[1].claim(value, 'other', 900)
        self.coords[0].release('510-a', token)
        with self.assertRaises(module.CoordinationError):
            self.coords[1].claim(value, 'other', 900)

    def test_integration_exclusive_even_after_expiry(self):
        token = self.claim()
        other = self.claim(1, '510-b', ['README.md'])
        self.coords[0].integrate('510-a', token, self.base, self.base)
        with self.assertRaises(module.CoordinationError):
            self.coords[1].integrate('510-b', other, self.base, self.base)
        with self.assertRaises(module.CoordinationError):
            self.coords[0].release('510-a', token)
        self.expiry('510-a')
        with self.assertRaises(module.CoordinationError):
            self.coords[1].integrate('510-b', other, self.base, self.base)
        self.coords[1].reconcile('510-a', 'Stopped old owner and reconciled publication.')
        self.coords[1].integrate('510-b', other, self.base, self.base)
        self.coords[1].finish_integration('510-b', other)
        self.coords[1].release('510-b', other)

    def test_ready_requires_exact_check_and_independent_review(self):
        token = self.claim()
        self.coords[0].integrate('510-a', token, self.base, self.base)
        with self.assertRaises(module.CoordinationError):
            self.coords[0].ready('510-a', token, self.base, self.base)
        self.record(token, 'checks_passed')
        with self.assertRaises(module.CoordinationError):
            self.record(token, 'review_approved', actor='writer-0')
        self.record(token, 'review_approved')
        self.coords[0].ready('510-a', token, self.base, self.base)
        self.record(token, 'review_changes')
        with self.assertRaises(module.CoordinationError):
            self.coords[0].ready('510-a', token, self.base, self.base)
        self.record(token, 'checks_passed')
        self.record(token, 'review_approved')
        self.coords[0].ready('510-a', token, self.base, self.base)
        # A branch/ref update invalidates observations rather than inheriting green.
        (self.worktrees[0] / 'new').write_text('new')
        self.git(self.worktrees[0], 'add', 'new')
        self.git(self.worktrees[0], 'commit', '-qm', 'change')
        with self.assertRaises(module.CoordinationError):
            self.coords[0].ready('510-a', token, self.base, self.base)
        with self.assertRaises(module.CoordinationError):
            self.coords[0].ready('510-a', token, self.git(self.worktrees[0], 'rev-parse', 'HEAD'), self.base)

    def test_integration_refuses_committed_scope_drift_and_dirty_candidate(self):
        token = self.claim()
        (self.worktrees[0] / 'outside').write_text('wrong scope')
        with self.assertRaises(module.CoordinationError):
            self.coords[0].integrate('510-a', token, self.base, self.base)
        self.git(self.worktrees[0], 'add', 'outside')
        self.git(self.worktrees[0], 'commit', '-qm', 'outside')
        with self.assertRaises(module.CoordinationError):
            self.coords[0].integrate('510-a', token, self.git(self.worktrees[0], 'rev-parse', 'HEAD'), self.base)

    def test_nul_path_output_preserves_leading_whitespace(self):
        token = self.claim(paths=['asg/lib'])
        outside = self.worktrees[0] / ' asg/lib/new'
        outside.parent.mkdir(parents=True)
        outside.write_text('outside declared scope')
        self.git(self.worktrees[0], 'add', '--', ' asg/lib/new')
        self.git(self.worktrees[0], 'commit', '-qm', 'outside whitespace path')
        head = self.git(self.worktrees[0], 'rev-parse', 'HEAD')
        with self.assertRaises(module.CoordinationError):
            self.coords[0].integrate('510-a', token, head, self.base)

    def test_metrics_unknowns_and_observed_outcomes_not_pr_count(self):
        with patch.object(module.time, 'time', return_value=100):
            token = self.claim()
        report = self.coords[0].report()['tasks'][0]
        self.assertIsNone(report['start_to_merge_seconds'])
        self.assertIsNone(report['recorded_ci_wait_seconds'])
        with patch.object(module.time, 'time', return_value=110):
            self.coords[0].integrate('510-a', token, self.base, self.base)
            self.record(token, 'ci_started')
        with patch.object(module.time, 'time', return_value=130):
            self.record(token, 'ci_finished')
            self.record(token, 'checks_passed')
            self.record(token, 'review_approved')
            self.record(token, 'outcome_verified')
            self.record(token, 'merged', merge_sha=self.base)
            self.coords[0].finish_integration('510-a', token)
            self.coords[0].release('510-a', token)
        self.record(token, 'escaped_defect')  # Reporting after release is supported.
        report = self.coords[0].report()['tasks'][0]
        self.assertEqual(report['start_to_merge_seconds'], 30)
        self.assertEqual(report['recorded_ci_wait_seconds'], 20)
        self.assertEqual(report['verified_user_outcomes'], 1)
        self.assertEqual(report['escaped_defect_observations'], 1)
        self.assertFalse(report['ci_observation_incomplete'])

    def test_unpaired_ci_and_duplicate_outcome_refused(self):
        token = self.claim()
        with self.assertRaises(module.CoordinationError):
            self.record(token, 'ci_finished')
        self.record(token, 'ci_started')
        with self.assertRaises(module.CoordinationError):
            self.record(token, 'ci_started')
        self.record(token, 'outcome_verified')
        self.assertEqual(self.coords[0].report()['tasks'][0]['verified_user_outcomes'], 0)
        with self.assertRaises(module.CoordinationError):
            self.record(token, 'outcome_verified')
        self.assertTrue(self.coords[0].report()['tasks'][0]['ci_observation_incomplete'])

    def test_corrupt_or_unknown_state_is_preserved_and_cli_redacts(self):
        self.coords[0].path.write_bytes(b'private-corrupt-record')
        before = self.coords[0].path.read_bytes()
        result = self.cli(0, 'status')
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('private-corrupt-record', result.stderr)
        self.assertEqual(self.coords[0].path.read_bytes(), before)
        self.coords[0].path.unlink()
        self.coords[0].status()
        with sqlite3.connect(self.coords[0].path) as db:
            db.execute('PRAGMA user_version=99')
        with self.assertRaises(module.CoordinationError):
            self.coords[0].status()

    def test_stale_outcome_does_not_count_and_new_revision_can_be_verified(self):
        token = self.claim(paths=['new'])
        self.record(token, 'outcome_verified')
        (self.worktrees[0] / 'new').write_text('new')
        self.git(self.worktrees[0], 'add', 'new')
        self.git(self.worktrees[0], 'commit', '-qm', 'new revision')
        head = self.git(self.worktrees[0], 'rev-parse', 'HEAD')
        self.coords[0].integrate('510-a', token, head, self.base)
        self.record(token, 'checks_passed', head=head)
        self.record(token, 'review_approved', head=head)
        self.record(token, 'merged', head=head, merge_sha=head)
        self.assertEqual(self.coords[0].report()['tasks'][0]['verified_user_outcomes'], 0)
        self.record(token, 'outcome_verified', head=head)
        self.assertEqual(self.coords[0].report()['tasks'][0]['verified_user_outcomes'], 1)

    def test_case_and_unicode_normalization_conflicts(self):
        self.claim(paths=['café'])
        with self.assertRaises(module.CoordinationError):
            self.claim(1, '510-b', ['CAFE\u0301/output'])

    def test_primary_checkout_cannot_claim(self):
        with self.assertRaises(module.CoordinationError):
            module.Coordinator(self.repo).claim(self.value(), 'main-writer', 900)

    def test_main_ancestry_is_required(self):
        token = self.claim()
        (self.repo / 'main-only').write_text('main')
        self.git(self.repo, 'add', 'main-only')
        self.git(self.repo, 'commit', '-qm', 'main advances')
        advanced = self.git(self.repo, 'rev-parse', 'HEAD')
        self.git(self.repo, 'update-ref', 'refs/remotes/origin/main', advanced)
        with self.assertRaises(module.CoordinationError):
            self.coords[0].integrate('510-a', token, self.base, advanced)

    def test_transaction_rolls_back_after_failure(self):
        self.claim()
        with self.assertRaises(module.CoordinationError):
            self.claim(1, '510-a', ['README.md'])
        self.claim(1, '510-b', ['README.md'])
        self.assertEqual(len(self.coords[0].status()['claims']), 2)


if __name__ == '__main__':
    unittest.main()
