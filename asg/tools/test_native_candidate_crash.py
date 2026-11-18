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

    def session_proof(self, launch=1, admission_crash=False):
        return {'sessionId': f'session-{self.nonce}', 'projectId': f'restart-{self.nonce}',
                'revision': 0 if admission_crash else 1,
                'dispatchCount': 0 if admission_crash else 1,
                'dispatchId': None if admission_crash else f'candidate-restart-{self.nonce}-1:3',
                'sessionSha256': 'b' * 64,
                'journalSha256': None if admission_crash else 'c' * 64,
                'candidateSha256': None if admission_crash else 'd' * 64,
                'executionSha256': None if admission_crash else 'e' * 64,
                'receiptPreparations': int(not admission_crash and launch == 1),
                'commandEntries': 3 if not admission_crash and launch == 1 else 0}

    def test_session_proof_validates_both_crash_boundaries_without_replay(self):
        for admission_crash in (False, True):
            for launch in (1, 2):
                value = self.session_proof(launch, admission_crash)
                self.assertEqual(fixture.read_session_proof(value, self.nonce, launch, admission_crash), value)

    def test_session_proof_refuses_wrong_identity_missing_records_and_new_effects(self):
        value = self.session_proof(2)
        for key, replacement in [('sessionId', 'other'), ('projectId', 'other'),
                                 ('dispatchId', 'wrong:3'), ('revision', True),
                                 ('dispatchCount', 2), ('sessionSha256', None),
                                 ('journalSha256', 'private'), ('candidateSha256', None),
                                 ('executionSha256', 'A' * 64), ('receiptPreparations', 1),
                                 ('commandEntries', 1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.read_session_proof(dict(value, **{key: replacement}), self.nonce, 2)
        for modified in (dict(value, extra='unbounded'), {k: v for k, v in value.items() if k != 'revision'}):
            with self.assertRaises(ValueError):
                fixture.read_session_proof(modified, self.nonce, 2)

    def test_session_proof_refuses_invalid_challenge_identity_and_mode_types(self):
        value = self.session_proof()
        for nonce, launch, mode in [('bad', 1, False), (self.nonce, True, False),
                                    (self.nonce, 3, False), (self.nonce, 1, 1)]:
            with self.subTest(nonce=nonce, launch=launch, mode=mode), self.assertRaises(ValueError):
                fixture.read_session_proof(value, nonce, launch, mode)

    def test_uncommitted_session_proof_refuses_partial_startup_or_effects(self):
        value = self.session_proof(admission_crash=True)
        for key, replacement in [('revision', 1), ('dispatchCount', 1),
                                 ('dispatchId', f'candidate-restart-{self.nonce}-1:3'),
                                 ('journalSha256', 'c' * 64), ('candidateSha256', 'd' * 64),
                                 ('executionSha256', 'e' * 64), ('receiptPreparations', 1),
                                 ('commandEntries', 1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.read_session_proof(dict(value, **{key: replacement}), self.nonce, 1, True)

    def test_bound_reports_require_matching_explicit_mode_and_retained_proof(self):
        for launch in (1, 2):
            self.report(launch, operation='test', stopRequested=True, stopSignalled=True,
                        savedStopPresent=True, sessionBound=True, sessionProof=self.session_proof(launch))
            fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True, session_bound=True)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True)

    def test_admission_crash_reports_refuse_partial_or_missing_baseline(self):
        for launch in (1, 2):
            value = self.report(launch, operation='test', sessionBound=True, admissionCrash=True,
                stopRequested=True, completedOperations=[], sessionProof=self.session_proof(launch, True),
                startupUnchanged=True, workingUnchanged=True, sourcesUnchanged=True, viewRendered=True)
            fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                                session_bound=True, admission_crash=True)
            value['startupUnchanged'] = False
            (self.root / f'launch-{launch}.json').write_text(json.dumps(value))
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                                    session_bound=True, admission_crash=True)

    def report(self, launch, operation='resolve', **changes):
        value = {'version': 11, 'launch': launch, 'nonce': self.nonce, 'dispatch': f'candidate-restart-{self.nonce}-1:3'}
        value.update(sessionBound=False, admissionCrash=False, sessionProof=None, promotionCrash=False, promote=False, retry=False, acknowledge=False, uncertain=False, publicationFault=False, intentUnchanged=True, running=False, runningMarker=False, runningCancelled=False, precommit=False, stopSignalled=False, stopSaveBlocked=False, savedStopPresent=False, stopRequested=False, stopUnchanged=True, operation=operation, completedOperations=fixture.OPERATIONS[:fixture.OPERATIONS.index(operation)])
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

    def test_uncertain_completion_requires_fault_and_no_invented_exit(self):
        self.report(1, operation='test', stopRequested=True, stopSignalled=True, running=True, runningMarker=True, uncertain=True, publicationFault=True)
        fixture.read_report(self.root, 1, self.nonce, operation='test', stop=True, running=True, uncertain=True)
        for changes in ({'retainedExit': -1}, {'runningCancelled': True}, {'intentUnchanged': False}, {'receiptOperations': ['resolve', 'analyze', 'test']}):
            value = dict(stopRequested=True, savedStopPresent=True, running=True, uncertain=True, retainedExit=None, receiptOperations=['resolve', 'analyze'])
            value.update(changes)
            self.report(2, operation='test', **value)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 2, self.nonce, operation='test', stop=True, running=True, uncertain=True)
        self.report(2, operation='test', stopRequested=True, savedStopPresent=True, running=True, uncertain=True, retainedExit=None, receiptOperations=['resolve', 'analyze'])
        fixture.read_report(self.root, 2, self.nonce, operation='test', stop=True, running=True, uncertain=True)

    def test_third_launch_requires_saved_action_fresh_consent_and_no_dispatch(self):
        common = dict(acknowledge=True, stopRequested=True, savedStopPresent=True, running=True, runningCancelled=True, retainedExit=-1)
        self.report(2, operation='test', **common, acknowledgedAfterRead=True, afterAcknowledgementPhase='awaitingApproval', noNewDispatch=True)
        fixture.read_report(self.root, 2, self.nonce, operation='test', stop=True, running=True, acknowledge=True)
        for changes in ({'actionUnchanged': False}, {'freshConsentRequired': False}, {'noNewDispatch': False}, {'executionPhase': 'executing'}):
            value = dict(common, interrupted=False, executionPhase='awaitingApproval', actionUnchanged=True, freshConsentRequired=True, noNewDispatch=True)
            value.update(changes)
            self.report(3, operation='test', **value)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 3, self.nonce, operation='test', stop=True, running=True, acknowledge=True)
        self.report(3, operation='test', **common, interrupted=False, executionPhase='awaitingApproval', actionUnchanged=True, freshConsentRequired=True, noNewDispatch=True)
        fixture.read_report(self.root, 3, self.nonce, operation='test', stop=True, running=True, acknowledge=True)

    def test_fresh_retry_requires_new_identity_actual_checks_and_old_evidence(self):
        common = dict(retry=True, acknowledge=True, stopRequested=True, savedStopPresent=True, running=True, runningCancelled=True, retainedExit=-1, interrupted=False, executionPhase='awaitingApproval', actionUnchanged=True, freshConsentRequired=True, noNewDispatch=True, newDispatch=f'candidate-restart-{self.nonce}-2:3', retryChecksPassed=True, oldEvidencePreserved=True)
        self.report(3, operation='test', **common, retriedAfterRead=True)
        fixture.read_report(self.root, 3, self.nonce, operation='test', stop=True, running=True, acknowledge=True, retry=True)
        for change in ({'newDispatch': f'candidate-restart-{self.nonce}-1:3'}, {'retryChecksPassed': False}, {'oldEvidencePreserved': False}):
            value = dict(common); value.update(change)
            self.report(4, operation='test', **value)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 4, self.nonce, operation='test', stop=True, running=True, acknowledge=True, retry=True)
        self.report(4, operation='test', **common)
        fixture.read_report(self.root, 4, self.nonce, operation='test', stop=True, running=True, acknowledge=True, retry=True)

    def test_promotion_requires_actual_transition_refusal_preservation_and_reopen(self):
        common = dict(promote=True, retry=True, acknowledge=True, stopRequested=True, savedStopPresent=True, running=True, runningCancelled=True, retainedExit=-1, interrupted=False, executionPhase='awaitingApproval', actionUnchanged=True, freshConsentRequired=True, noNewDispatch=True, newDispatch=f'candidate-restart-{self.nonce}-2:3', retryChecksPassed=True, oldEvidencePreserved=True)
        for launch, fields in [(4, dict(promotedAfterRead=True, refusedPublicationPreserved=True)), (5, dict(promotionSurvived=True))]:
            self.report(launch, operation='test', **common, **fields)
            fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True, running=True, acknowledge=True, retry=True, promote=True)
            for key in fields:
                broken = dict(fields); broken[key] = False
                self.report(launch, operation='test', **common, **broken)
                with self.assertRaises(ValueError):
                    fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True, running=True, acknowledge=True, retry=True, promote=True)

    def test_committed_gap_requires_no_controller_success_before_owned_crash(self):
        common = dict(promotionCrash=True, promote=True, retry=True, acknowledge=True, stopRequested=True, savedStopPresent=True, running=True, runningCancelled=True, retainedExit=-1, interrupted=False, executionPhase='awaitingApproval', actionUnchanged=True, freshConsentRequired=True, noNewDispatch=True, newDispatch=f'candidate-restart-{self.nonce}-2:3', retryChecksPassed=True, oldEvidencePreserved=True, promotedAfterRead=False, refusedPublicationPreserved=True, commitGapReady=True, controllerSuccessDelivered=False)
        self.report(4, operation='test', **common)
        fixture.read_report(self.root, 4, self.nonce, operation='test', stop=True, running=True, acknowledge=True, retry=True, promote=True, promotion_crash=True)
        for change in [{'commitGapReady': False}, {'controllerSuccessDelivered': True}, {'promotedAfterRead': True}, {'refusedPublicationPreserved': False}]:
            broken = dict(common); broken.update(change)
            self.report(4, operation='test', **broken)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, 4, self.nonce, operation='test', stop=True, running=True, acknowledge=True, retry=True, promote=True, promotion_crash=True)

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

    def test_bound_reopen_cannot_relabel_changed_session_or_startup_records(self):
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
                proof = outer.session_proof(self.launch)
                if self.launch == 2:
                    proof['sessionSha256'] = 'f' * 64
                outer.report(self.launch, operation='test', stopRequested=True,
                    stopSignalled=True, savedStopPresent=True, sessionBound=True, sessionProof=proof)
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
            with self.assertRaisesRegex(ValueError, 'records changed'):
                fixture.observe(self.root / 'fixture.app', sdk, operation='test', stop=True, session_bound=True)
        self.assertEqual([p.killed for p in processes], [True, False])

    def test_session_mode_refuses_unsupported_combinations_before_launch(self):
        for mode in [dict(admission_crash=True), dict(session_bound=True),
                     dict(session_bound=True, stop=True, operation='resolve'),
                     dict(session_bound=True, stop=True, operation='test', running=True)]:
            with self.subTest(mode=mode), mock.patch.object(fixture, 'inspect_bundle') as probe, \
                    mock.patch.object(fixture.subprocess, 'Popen') as launch:
                with self.assertRaises(ValueError):
                    fixture.observe(self.root, self.root, **mode)
                probe.assert_not_called()
                launch.assert_not_called()

    def test_protocol10_cannot_be_relabelled_as_session_evidence(self):
        self.report(1, version=10)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 1, self.nonce)

    def test_bundle_preflight_failure_launches_nothing(self):
        with mock.patch.object(fixture.sys, 'platform', 'darwin'), \
                mock.patch.object(fixture, 'inspect_bundle', side_effect=ValueError('wrong identity')), \
                mock.patch.object(fixture.subprocess, 'Popen') as launch:
            with self.assertRaises(ValueError):
                fixture.observe(self.root, self.root)
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
