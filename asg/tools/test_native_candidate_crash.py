# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

import native_candidate_crash as fixture


class CandidateCrashTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='asg-candidate-host-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.nonce = 'a' * 32

    def report(self, launch, operation='resolve', **changes):
        value = {'version': 5, 'launch': launch, 'nonce': self.nonce, 'dispatch': f'candidate-restart-{self.nonce}-1:3'}
        value.update(running=False, runningMarker=False, runningCancelled=False, precommit=False, stopSignalled=False, stopSaveBlocked=False, savedStopPresent=False, stopRequested=False, stopUnchanged=True, operation=operation, completedOperations=fixture.OPERATIONS[:fixture.OPERATIONS.index(operation)])
        if launch == 1:
            value['readyForCrash'] = True
        else:
            value.update(interrupted=True, retainedExit=0, receiptOperations=fixture.OPERATIONS[:fixture.OPERATIONS.index(operation) + 1], cleanup='unknown',
                         journalUnchanged=True, sourcesUnchanged=True, workingUnchanged=True, viewRendered=True, executionPhase='executing')
        value.update(changes)
        (self.root / f'launch-{launch}.json').write_text(json.dumps(value))
        return value

    def test_stale_or_unsafe_observations_are_refused(self):
        for changes in ({'nonce': 'b' * 32}, {'dispatch': 'candidate-p-1:4'}, {'dispatch': 'wrong-task:3'}, {'cleanup': 'confirmed'},
                        {'retainedExit': True}, {'workingUnchanged': False}, {'sourcesUnchanged': False}, {'viewRendered': False}):
            self.report(2, **changes)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 2, self.nonce)

    def test_each_fixed_operation_requires_exact_completed_prefix_and_receipts(self):
        for operation in fixture.OPERATIONS:
            self.report(2, operation=operation)
            fixture.read_report(self.root, 2, self.nonce, operation)
            self.report(2, operation=operation, completedOperations=['build'])
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 2, self.nonce, operation)
            self.report(2, operation=operation, receiptOperations=[])
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 2, self.nonce, operation)

    def test_stop_observation_requires_committed_unchanged_intent(self):
        for launch in (1, 2):
            self.report(launch, stopRequested=True, stopSignalled=True, savedStopPresent=True)
            fixture.read_report(self.root, launch, self.nonce, stop=True)
            self.report(launch, stopRequested=False)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, launch, self.nonce, stop=True)
        self.report(2, stopRequested=True, savedStopPresent=True, stopUnchanged=False)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 2, self.nonce, stop=True)

    def test_precommit_requires_blocked_signal_and_absent_saved_request(self):
        self.report(1, precommit=True, stopRequested=True, stopSignalled=True, stopSaveBlocked=True)
        fixture.read_report(self.root, 1, self.nonce, stop=True, precommit=True)
        for change in ({'stopSaveBlocked': False}, {'stopSignalled': False}):
            self.report(1, precommit=True, stopRequested=True, stopSignalled=True, stopSaveBlocked=True)
            value = json.loads((self.root / 'launch-1.json').read_text())
            value.update(change)
            (self.root / 'launch-1.json').write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 1, self.nonce, stop=True, precommit=True)
        self.report(2, precommit=True, stopRequested=True, savedStopPresent=False)
        fixture.read_report(self.root, 2, self.nonce, stop=True, precommit=True)
        self.report(2, precommit=True, stopRequested=True, savedStopPresent=True)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 2, self.nonce, stop=True, precommit=True)

    def test_running_test_requires_marker_and_actual_cancelled_receipt(self):
        self.report(1, operation='test', stopRequested=True, stopSignalled=True, running=True, runningMarker=True)
        fixture.read_report(self.root, 1, self.nonce, operation='test', stop=True, running=True)
        self.report(1, operation='test', stopRequested=True, stopSignalled=True, running=True, runningMarker=False)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 1, self.nonce, operation='test', stop=True, running=True)
        self.report(2, operation='test', stopRequested=True, savedStopPresent=True, running=True, runningCancelled=True, retainedExit=-1)
        fixture.read_report(self.root, 2, self.nonce, operation='test', stop=True, running=True)
        self.report(2, operation='test', stopRequested=True, savedStopPresent=True, running=True, runningCancelled=False, retainedExit=0)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 2, self.nonce, operation='test', stop=True, running=True)

    def test_ready_and_recovered_reports_are_distinct(self):
        self.report(1)
        self.assertTrue(fixture.read_report(self.root, 1, self.nonce)['readyForCrash'])
        self.report(2)
        self.assertTrue(fixture.read_report(self.root, 2, self.nonce)['interrupted'])
        self.report(1, readyForCrash=False)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 1, self.nonce)

    def test_linked_reports_cannot_authorize_a_crash(self):
        external = self.root / 'external'
        external.write_text('{}')
        (self.root / 'launch-1.json').symlink_to(external)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 1, self.nonce)

    def test_only_first_live_owned_process_is_crashed_after_handshake(self):
        sdk = self.root / 'sdk'
        (sdk / 'bin/cache').mkdir(parents=True)
        (sdk / 'bin/cache/flutter_tools.snapshot').write_text('existing cache')
        processes = []
        outer = self

        class Process:
            def __init__(self, *args, **kwargs):
                self.launch = len(processes) + 1
                self.killed = False
                processes.append(self)
                outer.report(self.launch)
            def poll(self):
                return -9 if self.killed else (0 if self.launch == 2 else None)
            def kill(self):
                self.killed = True
            def wait(self, timeout):
                return self.poll()

        with mock.patch.object(fixture.sys, 'platform', 'darwin'), \
                mock.patch.object(fixture, 'inspect_bundle', return_value=(self.root / 'executable', 'fixedhash')), \
                mock.patch.object(fixture.tempfile, 'mkdtemp', return_value=str(self.root)), \
                mock.patch.object(fixture.secrets, 'token_hex', return_value=self.nonce), \
                mock.patch.object(fixture.subprocess, 'Popen', side_effect=Process):
            result = fixture.observe(self.root / 'fixture.app', sdk)
        self.assertEqual([p.killed for p in processes], [True, False])
        self.assertEqual(len(result['observations']), 2)

    def test_bundle_preflight_failure_launches_nothing(self):
        with mock.patch.object(fixture.sys, 'platform', 'darwin'), \
                mock.patch.object(fixture, 'inspect_bundle', side_effect=ValueError('wrong identity')), \
                mock.patch.object(fixture.subprocess, 'Popen') as launch:
            with self.assertRaises(ValueError):
                fixture.observe(self.root, self.root)
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
