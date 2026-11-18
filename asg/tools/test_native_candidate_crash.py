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

    def report(self, launch, **changes):
        value = {'version': 1, 'launch': launch, 'nonce': self.nonce, 'dispatch': 'candidate-p-1:3'}
        if launch == 1:
            value['readyForCrash'] = True
        else:
            value.update(interrupted=True, retainedResolveExit=0, cleanup='unknown',
                         journalUnchanged=True, sourcesUnchanged=True, workingUnchanged=True, viewRendered=True, executionPhase='executing')
        value.update(changes)
        (self.root / f'launch-{launch}.json').write_text(json.dumps(value))
        return value

    def test_stale_or_unsafe_observations_are_refused(self):
        for changes in ({'nonce': 'b' * 32}, {'dispatch': 'candidate-p-1:4'}, {'cleanup': 'confirmed'},
                        {'retainedResolveExit': True}, {'workingUnchanged': False}, {'viewRendered': False}):
            self.report(2, **changes)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 2, self.nonce)

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
