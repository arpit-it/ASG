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

    def test_cancellation_proof_requires_intent_actual_receipt_and_no_new_effects(self):
        for launch in (1, 2):
            proof = self.session_proof(launch)
            proof.update(revision=2, cancellationRequested=True, receiptSha256='f' * 64,
                         commandEntries=1 if launch == 1 else 0)
            fixture.read_session_proof(proof, self.nonce, launch, session_cancel=True)
            for key, value in [('cancellationRequested', False), ('revision', 1),
                               ('receiptSha256', None), ('dispatchCount', 2),
                               ('commandEntries', 2), ('receiptPreparations', 2)]:
                with self.subTest(launch=launch, key=key), self.assertRaises(ValueError):
                    fixture.read_session_proof(dict(proof, **{key: value}), self.nonce, launch, session_cancel=True)

    def test_cancel_report_retains_only_the_actual_first_exit_without_promotion(self):
        for launch in (1, 2):
            proof = self.session_proof(launch)
            proof.update(revision=2, cancellationRequested=True, receiptSha256='f' * 64,
                         commandEntries=1 if launch == 1 else 0)
            fields = dict(sessionBound=True, sessionCancel=True, stopRequested=True,
                sessionProof=proof, completedOperations=['resolve'], receiptOperations=['resolve'],
                runFinished=True, candidatePhase='failed', pendingOperation='', executionPhase='verifying',
                retainedExit=0, promotionAllowed=False, candidateStopPresent=False, noLaterCommands=True, workingUnchanged=True,
                sourcesUnchanged=True, cancellationUnchanged=True, viewRendered=True)
            self.report(launch, operation='test', **fields)
            fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                                session_bound=True, session_cancel=True)
            for key, value in [('retainedExit', True), ('retainedExit', None), ('promotionAllowed', True),
                               ('noLaterCommands', False), ('pendingOperation', 'analyze'),
                               ('candidatePhase', 'ready'), ('cancellationUnchanged', False), ('candidateStopPresent', True)]:
                altered = dict(fields, **{key: value})
                self.report(launch, operation='test', **altered)
                with self.subTest(key=key), self.assertRaises(ValueError):
                    fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                                        session_bound=True, session_cancel=True)

    def retry_proof(self, launch):
        count = 2 if launch >= 3 else 1
        proof = dict(sessionId=f'session-{self.nonce}', projectId=f'restart-{self.nonce}',
            revision=count, dispatchCount=count,
            dispatchIds=[f'candidate-restart-{self.nonce}-{n}:3' for n in range(1, count + 1)],
            cancellationRequested=False, receiptPreparations=int(launch in (1, 3)),
            commandEntries=3 if launch == 1 else 4 if launch == 3 else 0,
            basisSha256='a' * 64, sessionSha256=('b' if count == 1 else 'c') * 64,
            journalSha256=('d' if launch == 1 else 'e' if launch == 2 else 'f') * 64,
            candidateSha256=('0' if count == 1 else '1') * 64,
            firstRunSha256=('2' if launch == 1 else '3') * 64,
            firstExecutionSha256=('4' if launch == 1 else '5') * 64,
            firstReceiptSha256='6' * 64, stopSha256='7' * 64,
            recoverySha256=None if launch == 1 else '8' * 64,
            secondExecutionSha256=None if count == 1 else '9' * 64,
            secondReceiptSha256=None if count == 1 else 'a' * 64)
        return proof

    def test_bound_retry_proof_tracks_explicit_actions_and_read_only_reopens(self):
        previous = None
        for launch in (1, 2, 3, 4):
            proof = self.retry_proof(launch)
            fixture.read_retry_proof(proof, self.nonce, launch)
            before = fixture.retry_digest(previous or proof)
            fixture.require_retry_transition(previous, proof, launch, before)
            previous = proof

    def test_bound_retry_refuses_lineage_rewrites_cancellation_and_replay(self):
        proof = self.retry_proof(3)
        for key, value in [('revision', True), ('dispatchCount', 1), ('cancellationRequested', True),
                           ('dispatchIds', [proof['dispatchIds'][1], proof['dispatchIds'][0]]),
                           ('secondReceiptSha256', None), ('commandEntries', 3)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.read_retry_proof(dict(proof, **{key: value}), self.nonce, 3)
        previous = self.retry_proof(2)
        for key in ('basisSha256', 'firstRunSha256', 'firstExecutionSha256', 'firstReceiptSha256', 'stopSha256', 'recoverySha256'):
            changed = dict(proof, **{key: 'b' * 64})
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.require_retry_transition(previous, changed, 3, fixture.retry_digest(previous))
        with self.assertRaises(ValueError):
            fixture.require_retry_transition(previous, proof, 3, 'f' * 64)
        final = self.retry_proof(4)
        final['journalSha256'] = 'b' * 64
        with self.assertRaises(ValueError):
            fixture.require_retry_transition(proof, final, 4, fixture.retry_digest(proof))

    def test_bound_retry_reports_require_full_mode_and_stage_proof(self):
        previous = None
        for launch in (1, 2, 3, 4):
            proof = self.retry_proof(launch)
            fields = dict(sessionBound=True, sessionRetryProof=proof,
                beforeActionSha256=fixture.retry_digest(previous or proof),
                retry=True, acknowledge=True, stopRequested=True, savedStopPresent=True,
                running=True, runningMarker=True, stopSignalled=True, runningCancelled=True,
                retainedExit=-1, interrupted=launch < 3,
                executionPhase='executing' if launch < 3 else 'awaitingApproval',
                acknowledgedAfterRead=launch == 2,
                afterAcknowledgementPhase='awaitingApproval' if launch == 2 else None,
                actionUnchanged=True, freshConsentRequired=True, noNewDispatch=True,
                newDispatch=f'candidate-restart-{self.nonce}-2:3', retryChecksPassed=True,
                oldEvidencePreserved=True, retriedAfterRead=launch == 3)
            self.report(launch, operation='test', **fields)
            fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                                running=True, acknowledge=True, retry=True, session_bound=True)
            changed = dict(fields, sessionProof=self.session_proof())
            self.report(launch, operation='test', **changed)
            with self.assertRaises(ValueError):
                fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                                    running=True, acknowledge=True, retry=True, session_bound=True)
            previous = proof

    def test_retry_proof_refuses_non_integer_or_out_of_range_stage(self):
        for launch in (True, None, '3', 0, 5):
            with self.subTest(launch=launch), self.assertRaises(ValueError):
                fixture.read_retry_proof(self.retry_proof(3), self.nonce, launch)

    def test_acknowledgement_cannot_claim_unchanged_journal_or_checkpoint(self):
        previous = self.retry_proof(1)
        proof = self.retry_proof(2)
        for key in ('journalSha256', 'firstRunSha256', 'firstExecutionSha256'):
            changed = dict(proof, **{key: previous[key]})
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.require_retry_transition(previous, changed, 2, fixture.retry_digest(previous))

    def promotion_proof(self, launch):
        proof = self.retry_proof(min(launch, 4))
        proof.update(workingSha256=('b' if launch < 4 else 'c') * 64,
                     previousSha256=None if launch < 4 else 'b' * 64,
                     workingPublished=launch >= 4,
                     secondExecutionPhase='completed' if launch >= 4 else 'verifying' if launch == 3 else None)
        if launch >= 4:
            proof['secondExecutionSha256'] = 'd' * 64
        return proof

    def test_bound_publication_changes_only_authorized_state_then_reopens_read_only(self):
        previous = None
        for launch in (1, 2, 3, 4, 5):
            proof = self.promotion_proof(launch)
            fixture.read_retry_proof(proof, self.nonce, launch, promote=True)
            fixture.require_retry_transition(previous, proof, launch, fixture.retry_digest(previous or proof), promote=True)
            previous = proof

    def test_bound_publication_refuses_missing_commit_history_or_rewritten_session(self):
        previous = self.promotion_proof(3)
        proof = self.promotion_proof(4)
        for key, value in [('workingSha256', previous['workingSha256']),
                           ('previousSha256', 'f' * 64), ('secondExecutionSha256', previous['secondExecutionSha256']),
                           ('sessionSha256', 'f' * 64), ('firstReceiptSha256', 'f' * 64),
                           ('journalSha256', 'b' * 64)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.require_retry_transition(previous, dict(proof, **{key: value}), 4,
                    fixture.retry_digest(previous), promote=True)
        for key, value in [('workingPublished', False), ('secondExecutionPhase', 'verifying'),
                           ('previousSha256', None), ('cancellationRequested', True)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.read_retry_proof(dict(proof, **{key: value}), self.nonce, 4, promote=True)
        final = self.promotion_proof(5)
        final['workingSha256'] = 'f' * 64
        with self.assertRaises(ValueError):
            fixture.require_retry_transition(proof, final, 5, fixture.retry_digest(proof), promote=True)

    def test_bound_promotion_reports_require_preview_and_correct_commit_gap_state(self):
        for crash in (False, True):
            for launch in (4, 5):
                proof = self.promotion_proof(launch)
                fields = dict(sessionBound=True, sessionRetryProof=proof,
                    beforeActionSha256=fixture.retry_digest(self.promotion_proof(launch - 1)),
                    promote=True, promotionCrash=crash, retry=True, acknowledge=True,
                    stopRequested=True, savedStopPresent=True, running=True, runningCancelled=True,
                    retainedExit=-1, interrupted=False, executionPhase='awaitingApproval',
                    actionUnchanged=True, freshConsentRequired=True, noNewDispatch=True,
                    newDispatch=f'candidate-restart-{self.nonce}-2:3', retryChecksPassed=True,
                    oldEvidencePreserved=True, promotedAfterRead=launch == 4 and not crash,
                    refusedPublicationPreserved=True, promotionSurvived=launch == 5,
                    previewResponded=launch == 4, commitGapReady=launch == 4 and crash,
                    controllerSuccessDelivered=False)
                self.report(launch, operation='test', **fields)
                fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                    running=True, acknowledge=True, retry=True, promote=True, promotion_crash=crash, session_bound=True)
                altered = dict(fields, previewResponded=launch != 4)
                self.report(launch, operation='test', **altered)
                with self.assertRaises(ValueError):
                    fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                        running=True, acknowledge=True, retry=True, promote=True, promotion_crash=crash, session_bound=True)

    def report(self, launch, operation='resolve', **changes):
        value = {'version': 14, 'launch': launch, 'nonce': self.nonce, 'dispatch': f'candidate-restart-{self.nonce}-1:3'}
        value.update(sessionBound=False, admissionCrash=False, sessionCancel=False, sessionProof=None, sessionRetryProof=None, beforeActionSha256=None, promotionCrash=False, promote=False, retry=False, acknowledge=False, uncertain=False, publicationFault=False, intentUnchanged=True, running=False, runningMarker=False, runningCancelled=False, precommit=False, stopSignalled=False, stopSaveBlocked=False, savedStopPresent=False, stopRequested=False, stopUnchanged=True, operation=operation, completedOperations=fixture.OPERATIONS[:fixture.OPERATIONS.index(operation)])
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
                     dict(session_bound=True, stop=True, operation='test', running=True),
                     dict(session_cancel=True),
                     dict(session_cancel=True, session_bound=True, stop=True, operation='test', admission_crash=True)]:
            with self.subTest(mode=mode), mock.patch.object(fixture, 'inspect_bundle') as probe, \
                    mock.patch.object(fixture.subprocess, 'Popen') as launch:
                with self.assertRaises(ValueError):
                    fixture.observe(self.root, self.root, **mode)
                probe.assert_not_called()
                launch.assert_not_called()

    def test_cancelled_session_cannot_reuse_uncancelled_admission_proof(self):
        proof = self.session_proof(2)
        for change in [dict(revision=2), dict(cancellationRequested=True),
                       dict(revision=2, cancellationRequested=True)]:
            changed = dict(proof, **change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                fixture.read_session_proof(changed, self.nonce, 2)

    def test_first_receipt_cancellation_cannot_relabel_the_later_test_gap(self):
        self.report(2, operation='test', sessionBound=True, sessionProof=self.session_proof(2),
            stopRequested=True, savedStopPresent=True, completedOperations=['resolve'],
            receiptOperations=['resolve'])
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 2, self.nonce, operation='test', stop=True, session_bound=True)

    def test_protocol10_cannot_be_relabelled_as_session_evidence(self):
        for version in (10, 11, 12, 13):
            self.report(1, version=version)
            with self.subTest(version=version), self.assertRaises(ValueError):
                fixture.read_report(self.root, 1, self.nonce)

    def test_bound_retry_partial_or_conflicting_consent_modes_launch_nothing(self):
        common = dict(session_bound=True, stop=True, operation='test', retry=True)
        for extras in [{}, {'running': True}, {'acknowledge': True},
                       {'running': True, 'acknowledge': True, 'admission_crash': True},
                       {'running': True, 'acknowledge': True, 'session_cancel': True}]:
            mode = dict(common, **extras)
            with self.subTest(mode=mode), mock.patch.object(fixture, 'inspect_bundle') as probe, \
                    mock.patch.object(fixture.subprocess, 'Popen') as launch:
                with self.assertRaises(ValueError):
                    fixture.observe(self.root, self.root, **mode)
                probe.assert_not_called()
                launch.assert_not_called()

    def test_invalid_acknowledgement_proof_prevents_launching_retry_app(self):
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
                proof = outer.retry_proof(self.launch)
                before = fixture.retry_digest(outer.retry_proof(max(1, self.launch - 1)))
                if self.launch == 2:
                    proof['firstReceiptSha256'] = 'f' * 64
                outer.report(self.launch, operation='test', sessionBound=True,
                    sessionRetryProof=proof, beforeActionSha256=before,
                    retry=True, acknowledge=True, stopRequested=True, savedStopPresent=True,
                    running=True, runningMarker=True, stopSignalled=True, runningCancelled=True,
                    retainedExit=-1, executionPhase='executing', noNewDispatch=True,
                    acknowledgedAfterRead=self.launch == 2,
                    afterAcknowledgementPhase='awaitingApproval' if self.launch == 2 else None)
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
            with self.assertRaisesRegex(ValueError, 'immutable prior evidence'):
                fixture.observe(self.root / 'fixture.app', sdk, operation='test', stop=True,
                    running=True, acknowledge=True, retry=True, session_bound=True)
        self.assertEqual(len(processes), 2)
        self.assertEqual([process.killed for process in processes], [True, False])

    def test_bound_promotion_partial_or_conflicting_modes_launch_nothing(self):
        common = dict(session_bound=True, stop=True, operation='test')
        for extras in [dict(promote=True), dict(promote=True, retry=True),
                       dict(promote=True, retry=True, acknowledge=True),
                       dict(promote=True, retry=True, acknowledge=True, running=True, session_cancel=True),
                       dict(promote=True, retry=True, acknowledge=True, running=True, admission_crash=True),
                       dict(promotion_crash=True, retry=True, acknowledge=True, running=True)]:
            mode = dict(common, **extras)
            with self.subTest(mode=mode), mock.patch.object(fixture, 'inspect_bundle') as probe, \
                    mock.patch.object(fixture.subprocess, 'Popen') as launch:
                with self.assertRaises(ValueError):
                    fixture.observe(self.root, self.root, **mode)
                probe.assert_not_called()
                launch.assert_not_called()

    def test_bundle_preflight_failure_launches_nothing(self):
        with mock.patch.object(fixture.sys, 'platform', 'darwin'), \
                mock.patch.object(fixture, 'inspect_bundle', side_effect=ValueError('wrong identity')), \
                mock.patch.object(fixture.subprocess, 'Popen') as launch:
            with self.assertRaises(ValueError):
                fixture.observe(self.root, self.root)
            launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
