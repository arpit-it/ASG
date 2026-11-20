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
                'taskHistory': None if admission_crash else self.history_proof(),
                'reopenContextSha256': None if admission_crash else 'a' * 64,
                'reopenEntryChecked': launch == 2, 'reopenEntryAvailable': launch == 2 and not admission_crash,
                'sessionSha256': 'b' * 64,
                'journalSha256': None if admission_crash else 'c' * 64,
                'candidateSha256': None if admission_crash else 'd' * 64,
                'executionSha256': None if admission_crash else 'e' * 64,
                'receiptPreparations': int(not admission_crash and launch == 1),
                'commandEntries': 3 if not admission_crash and launch == 1 else 0}

    def history_proof(self, cancelled=False, active=False, unknown=False):
        events = [['admitted', None, None, None]]
        for operation in fixture.OPERATIONS[:1 if cancelled and not active else 2]:
            events += [['pending', operation, None, None], ['result', operation, 0, False]]
        if not cancelled or active:
            events += [['pending', 'test', None, None]]
        if cancelled:
            events += ([['interrupted', 'test', None, None]] if unknown else
                       ([['result', 'test', 0, False]] if active else []) + [['finished', None, None, None]])
        return dict(sha256='f' * 64, projectionSha256='f' * 64, events=events,
                    withdrawalSequence=6 if active else 2 if cancelled else None,
                    pendingOperation='test' if not cancelled or unknown else None,
                    finished=cancelled and not unknown)

    def test_task_history_refuses_missing_changed_unknown_and_typed_false_facts(self):
        value = self.history_proof(cancelled=True, active=True, unknown=True)
        fixture.read_task_history(value, True, True, True, True)
        for key, replacement in [('sha256', None), ('projectionSha256', 'a' * 64),
                                 ('events', value['events'][:-1]),
                                 ('withdrawalSequence', True), ('withdrawalSequence', 5),
                                 ('pendingOperation', None), ('finished', True), ('finished', 0)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.read_task_history(dict(value, **{key: replacement}), True, True, True, True)
        for changed in (None, {}, dict(value, foreign='retained'),
                        {k: v for k, v in value.items() if k != 'events'}):
            with self.assertRaises(ValueError):
                fixture.read_task_history(changed, True, True, True, True)
        for position, field, replacement in [(2, 2, False), (2, 3, 0), (6, 2, 0)]:
            changed = json.loads(json.dumps(value))
            changed['events'][position][field] = replacement
            with self.assertRaises(ValueError):
                fixture.read_task_history(changed, True, True, True, True)
        with self.assertRaises(ValueError):
            fixture.read_task_history(value, False)
        with self.assertRaises(ValueError):
            fixture.read_task_history(value, True, True, True, False)

    def test_session_proof_requires_retained_task_history(self):
        # Protocol16 fingerprints other records but cannot prove task history.
        # Refuse this old shape before accepting crash/reopen evidence.
        with self.assertRaises(ValueError):
            fixture.read_session_proof({k: v for k, v in self.session_proof().items() if k != 'taskHistory'}, self.nonce, 1)

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
            proof.update(taskHistory=self.history_proof(cancelled=True), revision=2, cancellationRequested=True, reopenEntryAvailable=False, receiptSha256='f' * 64,
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
            proof.update(taskHistory=self.history_proof(cancelled=True), revision=2, cancellationRequested=True, reopenEntryAvailable=False, receiptSha256='f' * 64,
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

    def test_active_cancellation_requires_three_actual_receipts_and_boundary_hash(self):
        for launch in (1, 2):
            proof = self.session_proof(launch)
            proof.update(revision=2, cancellationRequested=True, reopenEntryAvailable=False, receiptSha256='f' * 64,
                taskHistory=self.history_proof(cancelled=True, active=True), activeBoundarySha256='a' * 64, commandEntries=3 if launch == 1 else 0)
            fixture.read_session_proof(proof, self.nonce, launch,
                session_cancel=True, session_cancel_active=True)
            fields = dict(sessionBound=True, sessionCancel=True, sessionCancelActive=True,
                stopRequested=True, sessionProof=proof, completedOperations=fixture.OPERATIONS[:3],
                receiptOperations=fixture.OPERATIONS[:3], runFinished=True,
                candidatePhase='failed', pendingOperation='', executionPhase='verifying',
                retainedExit=0, actualTestExit=0, activeBeforeExit=True, runningMarker=True,
                stopSignalled=False, promotionAllowed=False, candidateStopPresent=False,
                noLaterCommands=True, workingUnchanged=True, sourcesUnchanged=True,
                cancellationUnchanged=True, viewRendered=True)
            self.report(launch, operation='test', **fields)
            fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                session_bound=True, session_cancel=True, session_cancel_active=True)
            for key, value in [('activeBeforeExit', False), ('actualTestExit', True),
                               ('actualTestExit', -1), ('stopSignalled', True),
                               ('receiptOperations', ['resolve']), ('runningMarker', False)]:
                self.report(launch, operation='test', **dict(fields, **{key: value}))
                with self.subTest(key=key), self.assertRaises(ValueError):
                    fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True,
                        session_bound=True, session_cancel=True, session_cancel_active=True)
            for key, value in [('commandEntries', 1 if launch == 1 else 1), ('activeBoundarySha256', None)]:
                with self.subTest(key=key), self.assertRaises(ValueError):
                    fixture.read_session_proof(dict(proof, **{key: value}), self.nonce, launch,
                        session_cancel=True, session_cancel_active=True)
            with self.assertRaises(ValueError):
                fixture.read_session_proof(proof, self.nonce, launch, session_cancel=True)

    def test_unknown_cancellation_retains_prefix_and_refuses_invented_test_exit(self):
        mode = dict(session_bound=True, session_cancel=True,
                    session_cancel_active=True, session_cancel_unknown=True)
        for launch in (1, 2):
            proof = self.session_proof(launch)
            proof.update(revision=2, cancellationRequested=True, reopenEntryAvailable=False, receiptSha256='f' * 64,
                taskHistory=self.history_proof(cancelled=True, active=True, unknown=True), activeBoundarySha256='a' * 64, publicationFaultSha256='b' * 64,
                testResultPresent=False, commandEntries=3 if launch == 1 else 0)
            fields = dict(sessionBound=True, sessionCancel=True, sessionCancelActive=True,
                sessionCancelUnknown=True, stopRequested=True, sessionProof=proof,
                completedOperations=fixture.OPERATIONS[:2], receiptOperations=fixture.OPERATIONS[:2],
                runFinished=False, candidatePhase='failed', pendingOperation='test',
                failedOperation='test', executionPhase='executing', retainedExit=None,
                actualTestExit=None, activeBeforeExit=True, runningMarker=True,
                stopSignalled=False, promotionAllowed=False, candidateStopPresent=False,
                noLaterCommands=True, workingUnchanged=True, sourcesUnchanged=True,
                cancellationUnchanged=True, viewRendered=True, privateFaultObserved=True,
                cleanup='unknown', acknowledgementPresent=False)
            self.report(launch, operation='test', **fields)
            fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True, **mode)
            for key, value in [('actualTestExit', 0), ('actualTestExit', 73),
                               ('retainedExit', 0), ('privateFaultObserved', False),
                               ('cleanup', 'complete'), ('acknowledgementPresent', True),
                               ('runFinished', True), ('pendingOperation', ''),
                               ('failedOperation', ''), ('executionPhase', 'verifying'),
                               ('completedOperations', fixture.OPERATIONS[:3]),
                               ('receiptOperations', fixture.OPERATIONS[:3])]:
                self.report(launch, operation='test', **dict(fields, **{key: value}))
                with self.subTest(launch=launch, key=key), self.assertRaises(ValueError):
                    fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True, **mode)
            for key in ('actualTestExit', 'retainedExit', 'acknowledgementPresent'):
                missing = dict(fields)
                del missing[key]
                self.report(launch, operation='test', **missing)
                with self.subTest(missing=key), self.assertRaises(ValueError):
                    fixture.read_report(self.root, launch, self.nonce, operation='test', stop=True, **mode)
            for key, value in [('testResultPresent', True), ('testResultPresent', 0),
                               ('publicationFaultSha256', None), ('commandEntries', 1)]:
                with self.subTest(proof=key), self.assertRaises(ValueError):
                    fixture.read_session_proof(dict(proof, **{key: value}), self.nonce, launch,
                        session_cancel=True, session_cancel_active=True, session_cancel_unknown=True)

    def test_unknown_cancellation_incomplete_modes_launch_nothing(self):
        for mode in [dict(session_cancel_unknown=True),
                     dict(session_cancel_unknown=True, session_cancel=True),
                     dict(session_cancel_unknown=True, session_cancel_active=True),
                     dict(session_cancel_unknown=1),
                     dict(session_cancel_unknown=True, session_cancel_active=True,
                          session_cancel=True, session_bound=True, operation='test', stop=True,
                          uncertain=True)]:
            with self.subTest(mode=mode), mock.patch.object(fixture, 'inspect_bundle') as probe, \
                    mock.patch.object(fixture.subprocess, 'Popen') as launch:
                with self.assertRaises(ValueError):
                    fixture.observe(self.root, self.root, **mode)
                probe.assert_not_called()
                launch.assert_not_called()

    def test_active_completed_mode_cannot_relabel_unknown_test_result(self):
        proof = self.session_proof(1)
        proof.update(revision=2, cancellationRequested=True, reopenEntryAvailable=False, receiptSha256='f' * 64,
            taskHistory=self.history_proof(cancelled=True, active=True), activeBoundarySha256='a' * 64, commandEntries=3)
        self.report(1, operation='test', sessionBound=True, sessionCancel=True,
            sessionCancelActive=True, stopRequested=True, sessionProof=proof,
            completedOperations=fixture.OPERATIONS[:3], receiptOperations=fixture.OPERATIONS[:2],
            runFinished=False, candidatePhase='failed', pendingOperation='test',
            executionPhase='executing', retainedExit=None, actualTestExit=None,
            activeBeforeExit=True, runningMarker=True, stopSignalled=False,
            promotionAllowed=False, candidateStopPresent=False, noLaterCommands=True,
            workingUnchanged=True, sourcesUnchanged=True, cancellationUnchanged=True,
            viewRendered=True)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 1, self.nonce, operation='test', stop=True,
                session_bound=True, session_cancel=True, session_cancel_active=True)

    def test_active_cancel_incomplete_or_conflicting_modes_launch_nothing(self):
        for mode in [dict(session_cancel_active=True),
                     dict(session_cancel_active=True, session_cancel=True),
                     dict(session_cancel_active=True, session_cancel=True, session_bound=True, stop=True, operation='resolve'),
                     dict(session_cancel_active=True, session_cancel=True, session_bound=True, stop=True, operation='test', running=True),
                     dict(session_cancel_active=True, session_cancel=True, session_bound=True, stop=True, operation='test', admission_crash=True)]:
            with self.subTest(mode=mode), mock.patch.object(fixture, 'inspect_bundle') as probe, \
                    mock.patch.object(fixture.subprocess, 'Popen') as launch:
                with self.assertRaises(ValueError):
                    fixture.observe(self.root, self.root, **mode)
                probe.assert_not_called()
                launch.assert_not_called()

    def retry_proof(self, launch):
        count = 2 if launch >= 3 else 1
        proof = dict(sessionId=f'session-{self.nonce}', projectId=f'restart-{self.nonce}',
            revision=count, dispatchCount=count,
            dispatchIds=[f'candidate-restart-{self.nonce}-{n}:3' for n in range(1, count + 1)],
            reopenEntryChecked=launch != 1, reopenEntryAvailable=launch in (2, 3, 4),
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
        first = dict(self.history_proof(), runNumber=1, dispatchId=proof['dispatchIds'][0], reopenSha256='b' * 64)
        proof['taskHistories'] = [first]
        if count == 2:
            events = [['admitted', None, None, None]]
            for operation in fixture.OPERATIONS:
                events += [['pending', operation, None, None], ['result', operation, 0, False]]
            events += [['finished', None, None, None]]
            proof['taskHistories'].append(dict(sha256='c' * 64, projectionSha256='c' * 64,
                events=events, withdrawalSequence=None, pendingOperation=None, finished=True,
                runNumber=2, dispatchId=proof['dispatchIds'][1], reopenSha256='c' * 64))
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

    def test_retry_histories_refuse_swapped_runs_or_invented_first_completion(self):
        proof = self.retry_proof(3)
        for mutate in [
            lambda p: p['taskHistories'].reverse(),
            lambda p: p['taskHistories'][0].update(finished=True, pendingOperation=None),
            lambda p: p['taskHistories'][0].update(dispatchId=p['dispatchIds'][1]),
            lambda p: p['taskHistories'][1].update(runNumber=True),
            lambda p: p['taskHistories'][1].update(projectionSha256='b' * 64),
            lambda p: p['taskHistories'][1].update(finished=False),
            lambda p: p['taskHistories'][1]['events'][2].__setitem__(2, False),
            lambda p: p['taskHistories'][1].update(extra='foreign'),
            lambda p: p['taskHistories'].pop(),
        ]:
            changed = json.loads(json.dumps(proof))
            mutate(changed)
            with self.assertRaises(ValueError):
                fixture.read_retry_proof(changed, self.nonce, 3)
        orphan = self.retry_proof(1)
        orphan['taskHistories'].append(proof['taskHistories'][1])
        with self.assertRaises(ValueError):
            fixture.read_retry_proof(orphan, self.nonce, 1)

    def test_retry_cannot_rewrite_first_history_even_with_self_consistent_hashes(self):
        for stage in (2, 3, 4):
            previous = self.retry_proof(stage - 1)
            changed = self.retry_proof(stage)
            changed['taskHistories'][0].update(sha256='1' * 64, projectionSha256='1' * 64)
            fixture.read_retry_proof(changed, self.nonce, stage)
            with self.assertRaises(ValueError):
                fixture.require_retry_transition(previous, changed, stage, fixture.retry_digest(previous))

    def test_nested_retry_before_action_digest_is_key_order_independent(self):
        proof = self.retry_proof(3)
        changed = json.loads(json.dumps(proof))
        changed['taskHistories'] = [dict(reversed(list(h.items()))) for h in changed['taskHistories']]
        self.assertEqual(fixture.retry_digest(proof), fixture.retry_digest(changed))
        changed['taskHistories'][0]['sha256'] = '0' * 64
        self.assertNotEqual(fixture.retry_digest(proof), fixture.retry_digest(changed))

    def test_native_report_size_remains_bounded_before_parse(self):
        (self.root / 'launch-1.json').write_text(' ' * 8193)
        with self.assertRaises(ValueError):
            fixture.read_report(self.root, 1, self.nonce)

    def test_production_entry_requires_exact_observation_and_context_fingerprints(self):
        proof = self.retry_proof(3)
        for key, value in [('reopenEntryChecked', False), ('reopenEntryChecked', 1),
                           ('reopenEntryAvailable', False), ('reopenEntryAvailable', 1)]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.read_retry_proof(dict(proof, **{key: value}), self.nonce, 3)
        changed = json.loads(json.dumps(proof))
        changed['taskHistories'][0]['reopenSha256'] = None
        with self.assertRaises(ValueError):
            fixture.read_retry_proof(changed, self.nonce, 3)
        changed['taskHistories'][0]['reopenSha256'] = '1' * 64
        fixture.read_retry_proof(changed, self.nonce, 3)
        previous = self.retry_proof(2)
        with self.assertRaises(ValueError):
            fixture.require_retry_transition(previous, changed, 3, fixture.retry_digest(previous))
        for key, value in [('reopenContextSha256', None), ('reopenEntryChecked', False),
                           ('reopenEntryAvailable', False), ('reopenEntryAvailable', 1)]:
            changed = dict(self.session_proof(2), **{key: value})
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.read_session_proof(changed, self.nonce, 2)

    def test_retry_proof_requires_both_retained_task_histories(self):
        # Existing single-dispatch history proof does not cover retry stages.
        with self.assertRaises(ValueError):
            fixture.read_retry_proof({k: v for k, v in self.retry_proof(1).items() if k != 'taskHistories'}, self.nonce, 1)

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
        proof.update(reopenEntryAvailable=launch in (2, 3, 4), workingSha256=('b' if launch < 4 else 'c') * 64,
                     previousSha256=None if launch < 4 else 'b' * 64,
                     workingPublished=launch >= 4,
                     secondExecutionPhase='completed' if launch >= 4 else 'verifying' if launch == 3 else None)
        proof['publication'] = None if launch < 4 else dict(
            runNumber=2, boardTaskId='Tanalyze', dispatchId=proof['dispatchIds'][-1],
            sha256='e' * 64, projectionSha256='e' * 64,
            originalWorkingSha256=proof['previousSha256'], publishedWorkingSha256=proof['workingSha256'])
        if launch >= 4:
            proof['secondExecutionSha256'] = 'd' * 64
        return proof

    def test_publication_outcome_requires_exact_identity_and_current_record_fingerprints(self):
        proof = self.promotion_proof(4)
        fixture.read_retry_proof(proof, self.nonce, 4, promote=True)
        for key, replacement in [('runNumber', True), ('runNumber', 1),
                                 ('boardTaskId', 'foreign'), ('dispatchId', 'other:3'),
                                 ('sha256', None), ('projectionSha256', 'a' * 64),
                                 ('originalWorkingSha256', 'a' * 64), ('publishedWorkingSha256', 'a' * 64)]:
            changed = json.loads(json.dumps(proof))
            changed['publication'][key] = replacement
            with self.subTest(key=key), self.assertRaises(ValueError):
                fixture.read_retry_proof(changed, self.nonce, 4, promote=True)
        for replacement in (None, {}, dict(proof['publication'], extra=True)):
            with self.assertRaises(ValueError):
                fixture.read_retry_proof(dict(proof, publication=replacement), self.nonce, 4, promote=True)
        with self.assertRaises(ValueError):
            fixture.read_retry_proof(dict(self.promotion_proof(3), publication=proof['publication']), self.nonce, 3, promote=True)
        changed = self.promotion_proof(5)
        changed['publication'] = dict(changed['publication'], sha256='f' * 64, projectionSha256='f' * 64)
        fixture.read_retry_proof(changed, self.nonce, 5, promote=True)
        with self.assertRaises(ValueError):
            fixture.require_retry_transition(proof, changed, 5, fixture.retry_digest(proof), promote=True)

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
        value = {'version': 20, 'launch': launch, 'nonce': self.nonce, 'dispatch': f'candidate-restart-{self.nonce}-1:3'}
        value.update(sessionBound=False, admissionCrash=False, sessionCancel=False, sessionCancelActive=False, sessionCancelUnknown=False, sessionProof=None, sessionRetryProof=None, beforeActionSha256=None, promotionCrash=False, promote=False, retry=False, acknowledge=False, uncertain=False, publicationFault=False, intentUnchanged=True, running=False, runningMarker=False, runningCancelled=False, precommit=False, stopSignalled=False, stopSaveBlocked=False, savedStopPresent=False, stopRequested=False, stopUnchanged=True, operation=operation, completedOperations=fixture.OPERATIONS[:fixture.OPERATIONS.index(operation)])
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
        for version in (10, 11, 12, 13, 14, 15, 16, 17, 18, 19):
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

    def test_running_stop_cannot_relabel_after_exit_session_cancellation(self):
        with mock.patch.object(fixture, 'inspect_bundle') as probe, \
                mock.patch.object(fixture.subprocess, 'Popen') as launch:
            with self.assertRaises(ValueError):
                fixture.observe(self.root, self.root, operation='test', stop=True,
                    running=True, session_bound=True, session_cancel=True)
            probe.assert_not_called()
            launch.assert_not_called()

    def test_bundle_preflight_failure_launches_nothing(self):
        with mock.patch.object(fixture.sys, 'platform', 'darwin'), \
                mock.patch.object(fixture, 'inspect_bundle', side_effect=ValueError('wrong identity')), \
                mock.patch.object(fixture.subprocess, 'Popen') as launch:
            with self.assertRaises(ValueError):
                fixture.observe(self.root, self.root)
            launch.assert_not_called()


    def decision_report(self, launch):
        return {'version': 21, 'mode': 'task-decision', 'nonce': self.nonce, 'launch': launch,
                'decisionPresent': launch >= 3, 'decisionSha256': 'a' * 64 if launch >= 3 else None,
                'evidenceSha256': 'b' * 64 if launch >= 3 else None,
                'originalRecordsUnchanged': launch != 5, 'unrelatedRecordsUnchanged': True,
                'workingSha256': 'c' * 64, 'controllerBusy': launch in (2, 3),
                'controllerSuccessDelivered': launch >= 4, 'canConsent': launch == 1,
                'decisionCommits': int(launch == 3), 'sessionWithdrawn': launch == 5,
                'newDecisionRefused': launch == 5, 'sourceInspections': 0, 'sdkAttempts': 0,
                'modelAttempts': 0, 'previewAttempts': 0}

    def test_decision_protocol_requires_exact_absence_commit_reopen_and_withdrawal_facts(self):
        for launch in (1, 2, 3, 4, 5):
            value = self.decision_report(launch)
            report = self.root / f'launch-{launch}.json'
            report.write_text(json.dumps(value))
            self.assertEqual(fixture.read_decision_report(self.root, launch, self.nonce), value)
            changes = [('version', 20), ('launch', True), ('nonce', 'b' * 32),
                       ('decisionPresent', not value['decisionPresent']),
                       ('originalRecordsUnchanged', not value['originalRecordsUnchanged']),
                       ('unrelatedRecordsUnchanged', False), ('decisionCommits', True),
                       ('controllerBusy', not value['controllerBusy']),
                       ('controllerSuccessDelivered', not value['controllerSuccessDelivered']),
                       ('canConsent', not value['canConsent']), ('sdkAttempts', 1),
                       ('modelAttempts', 1), ('sourceInspections', 1), ('previewAttempts', 1),
                       ('workingSha256', None), ('sessionWithdrawn', not value['sessionWithdrawn']),
                       ('newDecisionRefused', not value['newDecisionRefused']),
                       ('decisionSha256', None if launch >= 3 else 'd' * 64),
                       ('evidenceSha256', None if launch >= 3 else 'e' * 64)]
            for key, replacement in changes:
                report.write_text(json.dumps(dict(value, **{key: replacement})))
                with self.subTest(launch=launch, key=key), self.assertRaises(ValueError):
                    fixture.read_decision_report(self.root, launch, self.nonce)
            for changed in (dict(value, extra=True), {k: v for k, v in value.items() if k != 'decisionCommits'}):
                report.write_text(json.dumps(changed))
                with self.assertRaises(ValueError):
                    fixture.read_decision_report(self.root, launch, self.nonce)

    def test_decision_report_refuses_symlink_and_oversize(self):
        target = self.root / 'target.json'
        target.write_text(json.dumps(self.decision_report(1)))
        report = self.root / 'launch-1.json'
        report.symlink_to(target)
        with self.assertRaises(ValueError):
            fixture.read_decision_report(self.root, 1, self.nonce)
        report.unlink()
        report.write_text(' ' * 8193)
        with self.assertRaises(ValueError):
            fixture.read_decision_report(self.root, 1, self.nonce)

    def test_decision_bundle_preflight_refusal_launches_nothing(self):
        with mock.patch.object(fixture.sys, 'platform', 'darwin'), \
                mock.patch.object(fixture, 'inspect_bundle', side_effect=ValueError('wrong identity')), \
                mock.patch.object(fixture.subprocess, 'Popen') as launch:
            with self.assertRaises(ValueError):
                fixture.observe_decision(self.root, self.root)
            launch.assert_not_called()



class RepairLineageTests(unittest.TestCase):
    """New protocol22 observations do not relabel protocol20/21 fixtures."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='asg-lineage-host-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.nonce = 'b' * 32
        self.protocol = fixture.native_repair_lineage

    @staticmethod
    def digest(text):
        import hashlib
        return hashlib.sha256(text.encode()).hexdigest()

    def records(self, count):
        result = {key: None for key in self.protocol.RECORD_SLOTS}
        for key in self.protocol.BASE_SLOTS:
            result[key] = self.digest(key + '-baseline')
        result['session'] = self.digest('raw-session0')
        for number in range(2, count + 1):
            result.update(journal=self.digest(f'journal{number}'),
                candidate=self.digest(f'candidate{number}'), session=self.digest(f'raw-session{number-1}'))
            for prefix in ('execution', 'history', 'context', 'companion'):
                result[f'{prefix}{number}'] = self.digest(f'{prefix}{number}')
        return result

    def report(self, launch, boundary='postcommit', corrupt=False):
        admitted = boundary == 'postcommit'
        target = 2 if launch <= 2 else 3
        before = self.records(1 if launch == 1 or not admitted else 2 if launch <= 3 else 3)
        after = self.records(target if admitted else 1)
        if corrupt:
            after['companion2'] = self.digest('opaque corrupt raw record')
        captured = self.digest('raw-session0' if target == 2 else 'raw-session1')
        project = f'restart-{self.nonce}'
        dispatch = f'candidate-{project}-{target}:3'
        counters = {key: 0 for key in self.protocol.COUNTER_KEYS}
        if launch == 1:
            counters.update(setupProviderCalls=1, sourceSetupCalls=1, failureSetupCalls=1, hostCreations=1)
        if launch == 3:
            counters.update(hostCreations=2, recoverySourceInspections=2)
        counters.update(startupCalls=int(launch in (1, 3)),
            startupRecordUpdates=7 if admitted and launch in (1, 3) else 0, corruptionControls=int(corrupt))
        return {'version': 22, 'mode': 'repair-lineage', 'nonce': self.nonce,
            'launch': launch, 'boundary': boundary, 'corruptOptional': corrupt,
            'stage': {1:'paused', 2:'read-only', 3:'retry-paused', 4:'retry-read-only'}[launch],
            'projectId': project, 'sessionId': f'session-{self.nonce}',
            'boardTaskId': 'Tanalyze', 'requirementId': 'R1',
            'requestedModel': self.protocol.MODEL, 'observedModel': self.protocol.MODEL,
            'failedRunNumber': 1, 'attemptNumber': 1, 'targetRunNumber': target,
            'targetDispatchId': dispatch, 'committedTargetRunNumber': target if admitted else None,
            'committedTargetDispatchId': dispatch if admitted else None,
            'proofState': 'unavailable' if corrupt else 'joined' if admitted else 'absent',
            'repairReference': {'version':1, 'projectId':project, 'attemptNumber':1,
                'attemptSha256':self.digest('terminal attempt1'), 'originSha256':after['repairOrigin']},
            'originalRequestSessionSha256': self.digest('raw-session0'),
            'capturedAdmissionSessionSha256':captured,
            'durableAdmissionSessionSha256':captured if admitted and not corrupt else None,
            'contextSha256':after[f'context{target}'], 'companionSha256':after[f'companion{target}'],
            'sessionRevision':target-1 if admitted else 0, 'sessionDispatchCount':target-1 if admitted else 0,
            'recordsBefore':before, 'recordsAfter':after,
            'unrelatedBeforeSha256':self.digest('unrelated records'),
            'unrelatedAfterSha256':self.digest('unrelated records'),
            'workingSourceSha256':self.digest('recorded working source manifest'),
            'preparedSourceSha256':self.digest('recorded prepared source manifest'), 'counters':counters}

    def validate(self, value, launch=1, boundary='postcommit', corrupt=False):
        return self.protocol.validate_report(value, launch, self.nonce, boundary, corrupt)

    def test_all_fixed_stages_and_complete_retry_transition_fit_report_bound(self):
        for boundary, launches in [('precommit', (1,2)), ('postcommit',(1,2,3,4))]:
            previous = None
            for launch in launches:
                value = self.report(launch,boundary)
                self.assertLess(len(json.dumps(value).encode()),8192)
                self.validate(value,launch,boundary)
                self.protocol.require_transition(previous,value)
                previous = value

    def test_corruption_is_raw_observation_not_joined_or_absent_proof(self):
        current = self.report(2,corrupt=True)
        self.validate(current,2,corrupt=True)
        self.protocol.require_transition(self.report(1),current)
        self.assertIsNotNone(current['companionSha256'])
        self.assertIsNone(current['durableAdmissionSessionSha256'])
        for patch in ({'proofState':'joined'}, {'proofState':'absent'},
                      {'durableAdmissionSessionSha256':current['capturedAdmissionSessionSha256']},
                      {'companionSha256':None}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                self.validate(dict(current,**patch),2,corrupt=True)

    def test_old_future_versions_and_wrong_mode_cannot_acquire_new_lineage(self):
        for patch in ({'version':20},{'version':21},{'version':23},{'version':True},
                      {'mode':'task-decision'},{'launch':True},{'targetRunNumber':True},
                      {'sessionRevision':True},{'attemptNumber':True},{'failedRunNumber':True}):
            with self.subTest(patch=patch),self.assertRaises(ValueError):
                self.validate(dict(self.report(1),**patch))

    def test_strict_report_reference_records_and_counter_member_sets(self):
        for section in ('report','repairReference','recordsBefore','recordsAfter','counters'):
            for extra in (False,True):
                value=self.report(1)
                target=value if section=='report' else value[section]
                if extra: target['unrecognized']='private irrelevant value'
                else: target.pop(next(iter(target)))
                with self.subTest(section=section,extra=extra),self.assertRaises(ValueError):
                    self.validate(value)

    def test_foreign_task_session_nonce_dispatch_reference_and_model_are_refused(self):
        for key,bad in {'nonce':'c'*32,'projectId':'foreign','sessionId':'foreign',
            'boardTaskId':'Ttest','requirementId':'R2','requestedModel':'wrong',
            'observedModel':'wrong','targetDispatchId':'candidate-foreign-2:3',
            'committedTargetRunNumber':1,'committedTargetDispatchId':'candidate-foreign-1:3'}.items():
            with self.subTest(key=key),self.assertRaises(ValueError):
                self.validate(dict(self.report(1),**{key:bad}))
        for key,bad in {'version':True,'projectId':'foreign','attemptNumber':2,
                        'attemptSha256':'x'*64,'originSha256':'f'*64}.items():
            value=self.report(1);value['repairReference'][key]=bad
            with self.subTest(reference=key),self.assertRaises(ValueError):self.validate(value)

    def test_captured_intent_does_not_count_as_committed_startup(self):
        value=self.report(1,'precommit')
        self.assertIsNotNone(value['capturedAdmissionSessionSha256'])
        for patch in ({'committedTargetRunNumber':2},
                      {'committedTargetDispatchId':value['targetDispatchId']},
                      {'durableAdmissionSessionSha256':value['capturedAdmissionSessionSha256']},
                      {'contextSha256':'a'*64},{'companionSha256':'a'*64},{'proofState':'joined'}):
            with self.subTest(patch=patch),self.assertRaises(ValueError):
                self.validate(dict(value,**patch),1,'precommit')

    def test_exact_seven_record_cohort_not_aggregate_or_partial_update(self):
        for slot in self.protocol.RECORD_SLOTS - {'candidate'}:
            value=self.report(1)
            if value['recordsAfter'][slot]!=value['recordsBefore'][slot]:
                value['recordsAfter'][slot]=value['recordsBefore'][slot]
            else:value['recordsAfter'][slot]='d'*64
            with self.subTest(slot=slot),self.assertRaises(ValueError):self.validate(value)
        value=self.report(1);value['unrelatedAfterSha256']='d'*64
        with self.assertRaises(ValueError):self.validate(value)

    def test_retry_can_rewrite_identical_candidate_bytes_with_seven_declared_updates(self):
        previous=self.report(2)
        retry=self.report(3)
        retry['recordsAfter']['candidate']=retry['recordsBefore']['candidate']
        self.validate(retry,3)
        self.assertEqual(retry['counters']['startupRecordUpdates'],7)
        self.protocol.require_transition(previous,retry)
        reopened=self.report(4)
        reopened['recordsBefore']['candidate']=retry['recordsAfter']['candidate']
        reopened['recordsAfter']['candidate']=retry['recordsAfter']['candidate']
        self.validate(reopened,4)
        self.protocol.require_transition(retry,reopened)

    def test_all_hashes_are_strict_and_raw_slots_match_context_companion(self):
        for key in ('originalRequestSessionSha256','capturedAdmissionSessionSha256',
                    'unrelatedBeforeSha256','workingSourceSha256','preparedSourceSha256'):
            for bad in (None,True,'F'*64,'g'*64,'a'*63):
                with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):
                    self.validate(dict(self.report(1),**{key:bad}))
        for key in ('contextSha256','companionSha256'):
            with self.subTest(key=key),self.assertRaises(ValueError):
                self.validate(dict(self.report(1),**{key:'d'*64}))

    def test_every_unexpected_effect_and_boolean_counter_is_refused(self):
        for key in self.protocol.COUNTER_KEYS:
            for bad in (True,-1,self.report(1)['counters'][key]+1):
                value=self.report(1);value['counters'][key]=bad
                with self.subTest(counter=key,bad=bad),self.assertRaises(ValueError):self.validate(value)

    def test_readonly_report_cannot_hide_native_record_writes(self):
        for slot in self.protocol.RECORD_SLOTS:
            value=self.report(2);value['recordsAfter'][slot]='d'*64
            with self.subTest(slot=slot),self.assertRaises(ValueError):self.validate(value,2)

    def test_retry_keeps_actual_pre_session_and_old_run_members(self):
        before=self.report(2);after=self.report(3)
        self.protocol.require_transition(before,after)
        for field in ('capturedAdmissionSessionSha256','originalRequestSessionSha256',
                      'workingSourceSha256','preparedSourceSha256'):
            value=self.report(3);value[field]='e'*64
            if field=='capturedAdmissionSessionSha256':value['durableAdmissionSessionSha256']='e'*64
            with self.subTest(field=field),self.assertRaises(ValueError):
                self.protocol.require_transition(before,value)
        value=self.report(3);value['recordsBefore']['companion2']='d'*64;value['recordsAfter']['companion2']='d'*64
        with self.assertRaises(ValueError):self.protocol.require_transition(before,value)

    def test_reopen_cannot_replace_reference_or_baseline_between_launches(self):
        for launch in (2,3,4):
            for change in ('reference','records','unrelated','captured'):
                value=self.report(launch)
                if change=='reference':value['repairReference']['attemptSha256']='e'*64
                elif change=='records':
                    value['recordsBefore']['working']='e'*64;value['recordsAfter']['working']='e'*64
                elif change=='unrelated':
                    value['unrelatedBeforeSha256']='e'*64;value['unrelatedAfterSha256']='e'*64
                else:
                    value['capturedAdmissionSessionSha256']='e'*64
                    value['durableAdmissionSessionSha256']='e'*64
                with self.subTest(launch=launch,change=change),self.assertRaises(ValueError):
                    self.protocol.require_transition(self.report(launch-1),value)
        with self.assertRaises(ValueError):self.protocol.require_transition(None,self.report(2))
        for bad in ('wrong', [], True):
            with self.subTest(previous=bad),self.assertRaises(ValueError):
                self.protocol.require_transition(bad,self.report(2))
        with self.assertRaises(ValueError):self.protocol.require_transition(self.report(2,corrupt=True),self.report(3))

    def test_invalid_fixed_scenarios_refuse_before_inspection_or_process(self):
        for mode in [dict(boundary='wrong'),dict(boundary='precommit',retry=True),
            dict(boundary='precommit',corrupt_optional=True),dict(retry=True,corrupt_optional=True),
            dict(retry=1),dict(corrupt_optional=1)]:
            with self.subTest(mode=mode),mock.patch.object(self.protocol,'inspect_bundle') as inspect, \
                    mock.patch.object(self.protocol.subprocess,'Popen') as launch:
                with self.assertRaises(ValueError):self.protocol.observe(self.root,self.root,**mode)
                inspect.assert_not_called();launch.assert_not_called()
        for args in [(3,'precommit',False),(4,'precommit',False),(1,'postcommit',True),
                     (3,'postcommit',True),(True,'postcommit',False)]:
            with self.subTest(args=args),self.assertRaises(ValueError):
                self.validate(self.report(1),args[0],args[1],args[2])

    def test_strict_reader_rejects_duplicate_json_nonfinite_oversize_symlink_and_partial(self):
        file=self.root/'launch-1.json'
        text=json.dumps(self.report(1))
        file.write_text(text)
        self.protocol.read_report(self.root,1,self.nonce,'postcommit')
        for raw in (text.replace('"version": 22','"version":22,"version":22',1),
                    text.replace('"setupProviderCalls": 1','"setupProviderCalls":1,"setupProviderCalls":1',1),
                    text.replace('"sessionRevision": 1','"sessionRevision":NaN',1),
                    ' '*8193):
            file.write_text(raw)
            with self.subTest(raw=raw[:30]),self.assertRaises(ValueError):
                self.protocol.read_report(self.root,1,self.nonce,'postcommit')
        file.write_text('{"private-token":')
        with self.assertRaises(json.JSONDecodeError) as caught:
            self.protocol.read_report(self.root,1,self.nonce,'postcommit')
        self.assertEqual(caught.exception.doc,'')
        file.unlink();target=self.root/'target.json';target.write_text(text);file.symlink_to(target)
        with self.assertRaises((ValueError,OSError)):
            self.protocol.read_report(self.root,1,self.nonce,'postcommit')

    def driver(self,boundary='postcommit',retry=False,corrupt=False,fail_launch=None,exit_code=0):
        sdk=self.root/'sdk';(sdk/'bin/cache').mkdir(parents=True,exist_ok=True)
        (sdk/'bin/cache/flutter_tools.snapshot').write_text('existing prepared SDK')
        processes=[];outer=self
        class Process:
            def __init__(self,*args,**kwargs):
                self.number=len(processes)+1;self.killed=False;processes.append(self)
                value=outer.report(self.number,boundary,corrupt and self.number==2)
                if fail_launch==self.number:value['counters']['sdkAttempts']=1
                (outer.root/f'launch-{self.number}.json').write_text(json.dumps(value))
            def poll(self):
                if self.killed:return -9
                return None if self.number in (1,3) else exit_code
            def kill(self):self.killed=True
            def wait(self,timeout):return self.poll()
        with mock.patch.object(self.protocol.sys,'platform','darwin'), \
                mock.patch.object(self.protocol,'inspect_bundle',return_value=(self.root/'owned-executable','a'*64)), \
                mock.patch.object(self.protocol.tempfile,'mkdtemp',return_value=str(self.root)) as make_root, \
                mock.patch.object(self.protocol.secrets,'token_hex',return_value=self.nonce), \
                mock.patch.object(self.protocol.subprocess,'Popen',side_effect=Process):
            try:
                result=self.protocol.observe(self.root/'fixture.app',sdk,boundary,retry,corrupt)
                make_root.assert_called_once_with(prefix='asg-candidate-crash-')
                return result,processes
            except ValueError:
                self.failed_processes=processes
                raise

    def test_owned_driver_crashes_only_its_paused_handles_and_pins_retry(self):
        value,processes=self.driver(retry=True)
        self.assertEqual([p.killed for p in processes],[True,False,True,False])
        self.assertEqual(len(value['launches']),4)
        self.assertEqual(value['version'],22)
        self.assertEqual(json.loads((self.root/'challenge.json').read_text()),
            {'mode':'repair-lineage','nonce':self.nonce,'launch':4,'boundary':'postcommit',
             'corruptOptional':False,'sdk':str(self.root/'sdk')})

    def test_owned_driver_precommit_and_corruption_are_separate_two_launch_scenarios(self):
        for boundary,corrupt in [('precommit',False),('postcommit',True)]:
            for path in self.root.glob('launch-*.json'):path.unlink()
            value,processes=self.driver(boundary=boundary,corrupt=corrupt)
            self.assertEqual([p.killed for p in processes],[True,False])
            self.assertEqual(value['corruptOptional'],corrupt)

    def test_driver_refuses_bad_reopen_before_starting_retry_and_retains_artifacts(self):
        with self.assertRaises(ValueError):self.driver(retry=True,fail_launch=2)
        self.assertEqual(len(self.failed_processes),2)
        self.assertEqual([p.killed for p in self.failed_processes],[True,False])
        self.assertTrue((self.root/'launch-2.json').is_file())

    def test_driver_refuses_nonzero_readonly_exit(self):
        with self.assertRaises(ValueError):self.driver(exit_code=2)
        self.assertEqual(len(self.failed_processes),2)

    def test_cli_requires_explicit_mode_and_rejects_all_legacy_scenarios(self):
        import contextlib
        import io
        base=['native_candidate_crash.py','--bundle','/supplied.app','--sdk','/supplied/sdk']
        bad=[['--lineage-retry'],['--lineage-corrupt'],['--lineage-boundary','precommit']]
        bad += [['--repair-lineage',flag] for flag in ('--task-decision','--stop','--precommit',
            '--running','--uncertain','--acknowledge','--retry','--promote','--promotion-crash',
            '--session-bound','--admission-crash','--session-cancel','--session-cancel-active','--session-cancel-unknown')]
        bad += [['--repair-lineage','--operation','test'],
                ['--repair-lineage','--lineage-boundary','precommit','--lineage-retry'],
                ['--repair-lineage','--lineage-retry','--lineage-corrupt']]
        for args in bad:
            with self.subTest(args=args),mock.patch.object(fixture.sys,'argv',base+args), \
                    mock.patch.object(self.protocol,'observe') as observe,contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:fixture.main()
                self.assertEqual(caught.exception.code,2);observe.assert_not_called()
        with mock.patch.object(fixture.sys,'argv',base+['--repair-lineage','--lineage-retry']), \
                mock.patch.object(self.protocol,'observe',return_value={'supplied':True}) as observe, \
                contextlib.redirect_stdout(io.StringIO()):
            fixture.main()
            observe.assert_called_once_with('/supplied.app','/supplied/sdk','postcommit',True,False)


class InitialLineageTests(unittest.TestCase):
    """Protocol23 observations preserve protocol20/21/22 fixture scopes."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='asg-lineage-host-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.nonce = 'b' * 32
        self.protocol = fixture.native_initial_lineage

    @staticmethod
    def digest(text):
        import hashlib
        return hashlib.sha256(text.encode()).hexdigest()

    def records(self, count):
        result = {key: None for key in self.protocol.RECORD_SLOTS}
        for key in self.protocol.BASE_SLOTS:
            result[key] = self.digest(key + '-baseline')
        result['session'] = self.digest('raw-session0')
        for number in range(1, count + 1):
            result.update(journal=self.digest(f'journal{number}'),
                candidate=self.digest(f'candidate{number}'), session=self.digest(f'raw-session{number}'))
            for prefix in ('execution', 'history', 'context', 'companion'):
                result[f'{prefix}{number}'] = self.digest(f'{prefix}{number}')
        return result

    def report(self, launch, boundary='postcommit', corrupt=False):
        admitted = boundary == 'postcommit'
        target = 1 if launch <= 2 else 2
        before = self.records(0 if launch == 1 or not admitted else 1 if launch <= 3 else 2)
        after = self.records(target if admitted else 0)
        if corrupt:
            after['companion1'] = self.digest('opaque corrupt raw record')
        captured = self.digest('raw-session0' if target == 1 else 'raw-session1')
        project = f'restart-{self.nonce}'
        dispatch = f'candidate-{project}-{target}:3'
        counters = {key: 0 for key in self.protocol.COUNTER_KEYS}
        if launch == 1:
            counters.update(setupProviderCalls=2, sourceSetupCalls=1, requestSetupCalls=2, hostCreations=1)
        if launch == 3:
            counters.update(hostCreations=2, recoverySourceInspections=2)
        counters.update(startupCalls=int(launch in (1, 3)),
            startupRecordUpdates=7 if admitted and launch in (1, 3) else 0, corruptionControls=int(corrupt))
        return {'version': 23, 'mode': 'initial-lineage', 'nonce': self.nonce,
            'launch': launch, 'boundary': boundary, 'corruptOptional': corrupt,
            'stage': {1:'paused', 2:'read-only', 3:'retry-paused', 4:'retry-read-only'}[launch],
            'projectId': project, 'sessionId': f'session-{self.nonce}',
            'boardTaskId': 'Tanalyze', 'requirementId': 'R1',
            'requestedModel': self.protocol.MODEL, 'observedModel': self.protocol.MODEL,
            'selectedRequestNumber': 1, 'latestRequestNumber': 2, 'requestCount': 2, 'targetRunNumber': target,
            'targetDispatchId': dispatch, 'committedTargetRunNumber': target if admitted else None,
            'committedTargetDispatchId': dispatch if admitted else None,
            'proofState': 'unavailable' if corrupt else 'joined' if admitted else 'absent',
            'requestReference': {'version':1, 'projectId':project, 'sessionId':f'session-{self.nonce}',
                'number':1, 'requestSha256':self.digest('terminal request1')},
            'selectedRequestSha256':self.digest('terminal request1'),
            'latestRequestSha256':self.digest('terminal request2'),
            'selectedReturnedSourceSha256':self.digest('identical returned file hash map'),
            'latestReturnedSourceSha256':self.digest('identical returned file hash map'),
            'originalRequestSessionSha256': self.digest('raw-session0'),
            'capturedAdmissionSessionSha256':captured,
            'durableAdmissionSessionSha256':captured if admitted and not corrupt else None,
            'contextSha256':after[f'context{target}'], 'companionSha256':after[f'companion{target}'],
            'sessionRevision':target if admitted else 0, 'sessionDispatchCount':target if admitted else 0,
            'recordsBefore':before, 'recordsAfter':after,
            'unrelatedBeforeSha256':self.digest('unrelated records'),
            'unrelatedAfterSha256':self.digest('unrelated records'),
            'workingSourceSha256':self.digest('recorded working source manifest'),
            'preparedSourceSha256':self.digest('recorded prepared source manifest'), 'counters':counters}

    def validate(self, value, launch=1, boundary='postcommit', corrupt=False):
        return self.protocol.validate_report(value, launch, self.nonce, boundary, corrupt)

    def test_all_fixed_stages_and_complete_retry_transition_fit_report_bound(self):
        for boundary, launches in [('precommit', (1,2)), ('postcommit',(1,2,3,4))]:
            previous = None
            for launch in launches:
                value = self.report(launch,boundary)
                self.assertLess(len(json.dumps(value).encode()),8192)
                self.validate(value,launch,boundary)
                self.protocol.require_transition(previous,value)
                previous = value

    def test_corruption_is_raw_observation_not_joined_or_absent_proof(self):
        current = self.report(2,corrupt=True)
        self.validate(current,2,corrupt=True)
        self.protocol.require_transition(self.report(1),current)
        self.assertIsNotNone(current['companionSha256'])
        self.assertIsNone(current['durableAdmissionSessionSha256'])
        for patch in ({'proofState':'joined'}, {'proofState':'absent'},
                      {'durableAdmissionSessionSha256':current['capturedAdmissionSessionSha256']},
                      {'companionSha256':None}):
            with self.subTest(patch=patch), self.assertRaises(ValueError):
                self.validate(dict(current,**patch),2,corrupt=True)

    def test_old_future_versions_and_wrong_mode_cannot_acquire_new_lineage(self):
        for patch in ({'version':20},{'version':21},{'version':22},{'version':24},{'version':True},
                      {'mode':'task-decision'},{'launch':True},{'targetRunNumber':True},
                      {'sessionRevision':True},{'selectedRequestNumber':True},{'requestCount':True},{'latestRequestNumber':True}):
            with self.subTest(patch=patch),self.assertRaises(ValueError):
                self.validate(dict(self.report(1),**patch))

    def test_strict_report_reference_records_and_counter_member_sets(self):
        for section in ('report','requestReference','recordsBefore','recordsAfter','counters'):
            for extra in (False,True):
                value=self.report(1)
                target=value if section=='report' else value[section]
                if extra: target['unrecognized']='private irrelevant value'
                else: target.pop(next(iter(target)))
                with self.subTest(section=section,extra=extra),self.assertRaises(ValueError):
                    self.validate(value)

    def test_foreign_task_session_nonce_dispatch_reference_and_model_are_refused(self):
        for key,bad in {'nonce':'c'*32,'projectId':'foreign','sessionId':'foreign',
            'boardTaskId':'Ttest','requirementId':'R2','requestedModel':'wrong',
            'observedModel':'wrong','targetDispatchId':'candidate-foreign-2:3',
            'committedTargetRunNumber':2,'committedTargetDispatchId':'candidate-foreign-1:3'}.items():
            with self.subTest(key=key),self.assertRaises(ValueError):
                self.validate(dict(self.report(1),**{key:bad}))
        for key,bad in {'version':True,'projectId':'foreign','number':2,
                        'requestSha256':'x'*64,'sessionId':'foreign'}.items():
            value=self.report(1);value['requestReference'][key]=bad
            with self.subTest(reference=key),self.assertRaises(ValueError):self.validate(value)

    def test_captured_intent_does_not_count_as_committed_startup(self):
        value=self.report(1,'precommit')
        self.assertIsNotNone(value['capturedAdmissionSessionSha256'])
        for patch in ({'committedTargetRunNumber':2},
                      {'committedTargetDispatchId':value['targetDispatchId']},
                      {'durableAdmissionSessionSha256':value['capturedAdmissionSessionSha256']},
                      {'contextSha256':'a'*64},{'companionSha256':'a'*64},{'proofState':'joined'}):
            with self.subTest(patch=patch),self.assertRaises(ValueError):
                self.validate(dict(value,**patch),1,'precommit')

    def test_exact_seven_record_cohort_not_aggregate_or_partial_update(self):
        for slot in self.protocol.RECORD_SLOTS - {'candidate'}:
            value=self.report(1)
            if value['recordsAfter'][slot]!=value['recordsBefore'][slot]:
                value['recordsAfter'][slot]=value['recordsBefore'][slot]
            else:value['recordsAfter'][slot]='d'*64
            with self.subTest(slot=slot),self.assertRaises(ValueError):self.validate(value)
        value=self.report(1);value['unrelatedAfterSha256']='d'*64
        with self.assertRaises(ValueError):self.validate(value)

    def test_retry_can_rewrite_identical_candidate_bytes_with_seven_declared_updates(self):
        previous=self.report(2)
        retry=self.report(3)
        retry['recordsAfter']['candidate']=retry['recordsBefore']['candidate']
        self.validate(retry,3)
        self.assertEqual(retry['counters']['startupRecordUpdates'],7)
        self.protocol.require_transition(previous,retry)
        reopened=self.report(4)
        reopened['recordsBefore']['candidate']=retry['recordsAfter']['candidate']
        reopened['recordsAfter']['candidate']=retry['recordsAfter']['candidate']
        self.validate(reopened,4)
        self.protocol.require_transition(retry,reopened)

    def test_all_hashes_are_strict_and_raw_slots_match_context_companion(self):
        for key in ('originalRequestSessionSha256','capturedAdmissionSessionSha256',
                    'unrelatedBeforeSha256','workingSourceSha256','preparedSourceSha256'):
            for bad in (None,True,'F'*64,'g'*64,'a'*63):
                with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):
                    self.validate(dict(self.report(1),**{key:bad}))
        for key in ('contextSha256','companionSha256'):
            with self.subTest(key=key),self.assertRaises(ValueError):
                self.validate(dict(self.report(1),**{key:'d'*64}))

    def test_every_unexpected_effect_and_boolean_counter_is_refused(self):
        for key in self.protocol.COUNTER_KEYS:
            for bad in (True,-1,self.report(1)['counters'][key]+1):
                value=self.report(1);value['counters'][key]=bad
                with self.subTest(counter=key,bad=bad),self.assertRaises(ValueError):self.validate(value)

    def test_readonly_report_cannot_hide_native_record_writes(self):
        for slot in self.protocol.RECORD_SLOTS:
            value=self.report(2);value['recordsAfter'][slot]='d'*64
            with self.subTest(slot=slot),self.assertRaises(ValueError):self.validate(value,2)

    def test_retry_keeps_actual_pre_session_and_old_run_members(self):
        before=self.report(2);after=self.report(3)
        self.protocol.require_transition(before,after)
        for field in ('capturedAdmissionSessionSha256','originalRequestSessionSha256',
                      'workingSourceSha256','preparedSourceSha256'):
            value=self.report(3);value[field]='e'*64
            if field=='capturedAdmissionSessionSha256':value['durableAdmissionSessionSha256']='e'*64
            with self.subTest(field=field),self.assertRaises(ValueError):
                self.protocol.require_transition(before,value)
        value=self.report(3);value['recordsBefore']['companion1']='d'*64;value['recordsAfter']['companion1']='d'*64
        with self.assertRaises(ValueError):self.protocol.require_transition(before,value)

    def test_reopen_cannot_replace_reference_or_baseline_between_launches(self):
        for launch in (2,3,4):
            for change in ('reference','records','unrelated','captured'):
                value=self.report(launch)
                if change=='reference':value['requestReference']['requestSha256']='e'*64
                elif change=='records':
                    value['recordsBefore']['working']='e'*64;value['recordsAfter']['working']='e'*64
                elif change=='unrelated':
                    value['unrelatedBeforeSha256']='e'*64;value['unrelatedAfterSha256']='e'*64
                else:
                    value['capturedAdmissionSessionSha256']='e'*64
                    value['durableAdmissionSessionSha256']='e'*64
                with self.subTest(launch=launch,change=change),self.assertRaises(ValueError):
                    self.protocol.require_transition(self.report(launch-1),value)
        with self.assertRaises(ValueError):self.protocol.require_transition(None,self.report(2))
        for bad in ('wrong', [], True):
            with self.subTest(previous=bad),self.assertRaises(ValueError):
                self.protocol.require_transition(bad,self.report(2))
        with self.assertRaises(ValueError):self.protocol.require_transition(self.report(2,corrupt=True),self.report(3))

    def test_invalid_fixed_scenarios_refuse_before_inspection_or_process(self):
        for mode in [dict(boundary='wrong'),dict(boundary='precommit',retry=True),
            dict(boundary='precommit',corrupt_optional=True),dict(retry=True,corrupt_optional=True),
            dict(retry=1),dict(corrupt_optional=1)]:
            with self.subTest(mode=mode),mock.patch.object(self.protocol,'inspect_bundle') as inspect, \
                    mock.patch.object(self.protocol.subprocess,'Popen') as launch:
                with self.assertRaises(ValueError):self.protocol.observe(self.root,self.root,**mode)
                inspect.assert_not_called();launch.assert_not_called()
        for args in [(3,'precommit',False),(4,'precommit',False),(1,'postcommit',True),
                     (3,'postcommit',True),(True,'postcommit',False)]:
            with self.subTest(args=args),self.assertRaises(ValueError):
                self.validate(self.report(1),args[0],args[1],args[2])

    def test_strict_reader_rejects_duplicate_json_nonfinite_oversize_symlink_and_partial(self):
        file=self.root/'launch-1.json'
        text=json.dumps(self.report(1))
        file.write_text(text)
        self.protocol.read_report(self.root,1,self.nonce,'postcommit')
        for raw in (text.replace('"version": 23','"version":23,"version":23',1),
                    text.replace('"setupProviderCalls": 2','"setupProviderCalls":2,"setupProviderCalls":2',1),
                    text.replace('"sessionRevision": 1','"sessionRevision":NaN',1),
                    ' '*8193):
            file.write_text(raw)
            with self.subTest(raw=raw[:30]),self.assertRaises(ValueError):
                self.protocol.read_report(self.root,1,self.nonce,'postcommit')
        file.write_text('{"private-token":')
        with self.assertRaises(json.JSONDecodeError) as caught:
            self.protocol.read_report(self.root,1,self.nonce,'postcommit')
        self.assertEqual(caught.exception.doc,'')
        file.unlink();target=self.root/'target.json';target.write_text(text);file.symlink_to(target)
        with self.assertRaises((ValueError,OSError)):
            self.protocol.read_report(self.root,1,self.nonce,'postcommit')

    def driver(self,boundary='postcommit',retry=False,corrupt=False,fail_launch=None,exit_code=0):
        sdk=self.root/'sdk';(sdk/'bin/cache').mkdir(parents=True,exist_ok=True)
        (sdk/'bin/cache/flutter_tools.snapshot').write_text('existing prepared SDK')
        processes=[];outer=self
        class Process:
            def __init__(self,*args,**kwargs):
                self.number=len(processes)+1;self.killed=False;processes.append(self)
                value=outer.report(self.number,boundary,corrupt and self.number==2)
                if fail_launch==self.number:value['counters']['sdkAttempts']=1
                (outer.root/f'launch-{self.number}.json').write_text(json.dumps(value))
            def poll(self):
                if self.killed:return -9
                return None if self.number in (1,3) else exit_code
            def kill(self):self.killed=True
            def wait(self,timeout):return self.poll()
        with mock.patch.object(self.protocol.sys,'platform','darwin'), \
                mock.patch.object(self.protocol,'inspect_bundle',return_value=(self.root/'owned-executable','a'*64)), \
                mock.patch.object(self.protocol.tempfile,'mkdtemp',return_value=str(self.root)) as make_root, \
                mock.patch.object(self.protocol.secrets,'token_hex',return_value=self.nonce), \
                mock.patch.object(self.protocol.subprocess,'Popen',side_effect=Process):
            try:
                result=self.protocol.observe(self.root/'fixture.app',sdk,boundary,retry,corrupt)
                make_root.assert_called_once_with(prefix='asg-candidate-crash-')
                return result,processes
            except ValueError:
                self.failed_processes=processes
                raise

    def test_owned_driver_crashes_only_its_paused_handles_and_pins_retry(self):
        value,processes=self.driver(retry=True)
        self.assertEqual([p.killed for p in processes],[True,False,True,False])
        self.assertEqual(len(value['launches']),4)
        self.assertEqual(value['version'],23)
        self.assertEqual(json.loads((self.root/'challenge.json').read_text()),
            {'mode':'initial-lineage','nonce':self.nonce,'launch':4,'boundary':'postcommit',
             'corruptOptional':False,'sdk':str(self.root/'sdk')})

    def test_owned_driver_precommit_and_corruption_are_separate_two_launch_scenarios(self):
        for boundary,corrupt in [('precommit',False),('postcommit',True)]:
            for path in self.root.glob('launch-*.json'):path.unlink()
            value,processes=self.driver(boundary=boundary,corrupt=corrupt)
            self.assertEqual([p.killed for p in processes],[True,False])
            self.assertEqual(value['corruptOptional'],corrupt)

    def test_driver_refuses_bad_reopen_before_starting_retry_and_retains_artifacts(self):
        with self.assertRaises(ValueError):self.driver(retry=True,fail_launch=2)
        self.assertEqual(len(self.failed_processes),2)
        self.assertEqual([p.killed for p in self.failed_processes],[True,False])
        self.assertTrue((self.root/'launch-2.json').is_file())

    def test_driver_refuses_nonzero_readonly_exit(self):
        with self.assertRaises(ValueError):self.driver(exit_code=2)
        self.assertEqual(len(self.failed_processes),2)

    def test_cli_requires_explicit_mode_and_rejects_all_legacy_scenarios(self):
        import contextlib
        import io
        base=['native_candidate_crash.py','--bundle','/supplied.app','--sdk','/supplied/sdk']
        bad=[['--initial-retry'],['--initial-corrupt'],['--initial-boundary','precommit']]
        bad += [['--initial-lineage',flag] for flag in ('--repair-lineage','--task-decision','--stop','--precommit',
            '--running','--uncertain','--acknowledge','--retry','--promote','--promotion-crash',
            '--session-bound','--admission-crash','--session-cancel','--session-cancel-active','--session-cancel-unknown')]
        bad += [['--initial-lineage','--lineage-boundary','postcommit'],
                ['--initial-lineage','--lineage-retry'],['--initial-lineage','--lineage-corrupt'],
                ['--repair-lineage','--initial-retry'],['--initial-lineage','--operation','test'],
                ['--initial-lineage','--initial-boundary','precommit','--initial-retry'],
                ['--initial-lineage','--initial-retry','--initial-corrupt']]
        for args in bad:
            with self.subTest(args=args),mock.patch.object(fixture.sys,'argv',base+args), \
                    mock.patch.object(self.protocol,'observe') as observe,contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:fixture.main()
                self.assertEqual(caught.exception.code,2);observe.assert_not_called()
        with mock.patch.object(fixture.sys,'argv',base+['--initial-lineage','--initial-retry']), \
                mock.patch.object(self.protocol,'observe',return_value={'supplied':True}) as observe, \
                contextlib.redirect_stdout(io.StringIO()):
            fixture.main()
            observe.assert_called_once_with('/supplied.app','/supplied/sdk','postcommit',True,False)


    def test_selected_older_request_cannot_be_replaced_by_latest_equal_source_return(self):
        value=self.report(1)
        self.assertEqual(value['selectedReturnedSourceSha256'],value['latestReturnedSourceSha256'])
        self.assertNotEqual(value['selectedRequestSha256'],value['latestRequestSha256'])
        for patch in ({'selectedRequestNumber':2}, {'latestRequestNumber':1}, {'requestCount':1},
                      {'latestRequestSha256':value['selectedRequestSha256']},
                      {'selectedRequestSha256':value['latestRequestSha256']},
                      {'latestReturnedSourceSha256':'e'*64}):
            with self.subTest(patch=patch),self.assertRaises(ValueError):
                self.validate(dict(value,**patch))
        value=self.report(1);value['requestReference']['number']=2
        value['requestReference']['requestSha256']=value['latestRequestSha256']
        value['selectedRequestSha256']=value['latestRequestSha256']
        with self.assertRaises(ValueError):self.validate(value)

    def test_initial_baseline_has_no_candidate_or_run_and_no_opposite_repair_slots(self):
        for boundary in ('precommit','postcommit'):
            value=self.report(1,boundary)
            self.assertEqual({k for k,v in value['recordsBefore'].items() if v is not None},
                             {'working','requestJournal','session'})
            for section in ('recordsBefore','recordsAfter'):
                for slot in ('repairCompanion1','repairCompanion2'):
                    changed=self.report(1,boundary);changed[section][slot]='e'*64
                    with self.subTest(boundary=boundary,section=section,slot=slot),self.assertRaises(ValueError):
                        self.validate(changed,1,boundary)

    def test_request_journal_and_terminal_entries_stay_pinned_across_every_launch(self):
        for launch in (2,3,4):
            for key in ('selectedRequestSha256','latestRequestSha256',
                        'selectedReturnedSourceSha256','latestReturnedSourceSha256'):
                changed=self.report(launch);changed[key]='e'*64
                if key=='selectedRequestSha256':changed['requestReference']['requestSha256']='e'*64
                if 'ReturnedSource' in key:
                    changed['selectedReturnedSourceSha256']=changed['latestReturnedSourceSha256']='e'*64
                with self.subTest(launch=launch,key=key),self.assertRaises(ValueError):
                    self.protocol.require_transition(self.report(launch-1),changed)
            changed=self.report(launch)
            changed['recordsBefore']['requestJournal']=changed['recordsAfter']['requestJournal']='e'*64
            with self.assertRaises(ValueError):
                self.protocol.require_transition(self.report(launch-1),changed)

    def test_reader_rejects_nonregular_fifo_without_blocking(self):
        import os
        file=self.root/'launch-1.json'
        os.mkfifo(file)
        with self.assertRaises(ValueError):
            self.protocol.read_report(self.root,1,self.nonce,'postcommit')

class UnresolvedInitialTests(unittest.TestCase):
    """Protocol24 fixed observations keep unknown outcomes unknown."""
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='asg-unresolved-host-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve()
        self.nonce='c'*32
        self.protocol=fixture.native_initial_unresolved

    @staticmethod
    def digest(text):
        import hashlib
        return hashlib.sha256(text.encode()).hexdigest()

    def records(self, count):
        result={key:None for key in self.protocol.RECORD_SLOTS}
        result.update(working=self.digest('working'),session=self.digest('raw session'))
        if count:result['requestJournal']=self.digest(f'journal{count}')
        return result

    def report(self, launch):
        fresh=launch>=3;count=2 if fresh else 1;project=f'restart-{self.nonce}';session=f'session-{self.nonce}'
        counters={key:0 for key in self.protocol.COUNTER_KEYS}
        if launch==1:counters.update(setupCalls=1,proposalCalls=1,reservationCommits=1)
        if launch==3:counters.update(proposalCalls=1,reservationCommits=1,reservationReturns=1,
                                    suppliedProviderCalls=1,proposalReturns=1,terminalCommits=1)
        return {'version':24,'mode':'initial-unresolved','nonce':self.nonce,'launch':launch,
            'explicitNext':fresh,'stage':{1:'reserved-paused',2:'read-only',3:'fresh-return-paused',4:'fresh-read-only'}[launch],
            'projectId':project,'sessionId':session,'boardTaskId':'Tanalyze','requirementId':'R1',
            'requestedModel':self.protocol.MODEL,'requestCount':count,'unresolvedRequestNumber':1,
            'latestRequestNumber':count,'unresolvedRequestStatus':'reserved',
            'latestRequestStatus':'returnedValidated' if fresh else 'reserved',
            'unresolvedRequestSha256':self.digest('reserved request1'),
            'latestRequestSha256':self.digest('returned request2' if fresh else 'reserved request1'),
            'unresolvedResponseModel':None,'latestResponseModel':self.protocol.MODEL if fresh else None,
            'unresolvedReturnedSourceSha256':None,'latestReturnedSourceSha256':self.digest('returned map') if fresh else None,
            'originalSessionSha256':self.digest('raw session'),'sessionRevision':0,'sessionDispatchCount':0,
            'requestReference':{'version':1,'projectId':project,'sessionId':session,'number':2,
                'requestSha256':self.digest('returned request2')} if fresh else None,
            'recordsBefore':self.records(0 if launch==1 else 1 if launch<=3 else 2),
            'recordsAfter':self.records(count),'unrelatedBeforeSha256':self.digest('unrelated'),
            'unrelatedAfterSha256':self.digest('unrelated'),'declaredSourceSha256':self.digest('declared metadata'),
            'counters':counters}

    def validate(self,value,launch=1):
        return self.protocol.validate_report(value,launch,self.nonce,launch>=3)

    def test_four_stage_contract_and_cross_launch_chain_fit8192(self):
        previous=None
        for launch in (1,2,3,4):
            value=self.report(launch)
            self.assertLess(len(json.dumps(value).encode()),8192)
            self.assertEqual(self.validate(value,launch),value)
            self.protocol.require_transition(previous,value);previous=value

    def test_wrong_protocol_identity_and_boolean_ints_refused(self):
        bad={'version':23,'mode':'initial-lineage','nonce':'f'*32,'launch':True,
            'explicitNext':1,'stage':'read-only','projectId':'p','sessionId':'s','boardTaskId':'Ttest',
            'requirementId':'R2','requestedModel':'wrong','requestCount':True,'unresolvedRequestNumber':2,
            'latestRequestNumber':2,'sessionRevision':True,'sessionDispatchCount':1}
        for key,value in bad.items():
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(dict(self.report(1),**{key:value}))
        for version in (20,21,22,23,25,True):
            with self.subTest(version=version),self.assertRaises(ValueError):self.validate(dict(self.report(1),version=version))
        for args in [(True,self.nonce,False),(1,'Z'*32,False),(2,self.nonce,True),(3,self.nonce,False)]:
            with self.subTest(args=args),self.assertRaises(ValueError):self.protocol.validate_report(self.report(1),*args)

    def test_unknown_request_never_acquires_response_reference_or_returned_state(self):
        for launch in (1,2,3,4):
            for patch in ({'unresolvedRequestStatus':'returnedValidated'}, {'unresolvedResponseModel':self.protocol.MODEL},
                          {'unresolvedReturnedSourceSha256':'f'*64}):
                with self.subTest(launch=launch,patch=patch),self.assertRaises(ValueError):self.validate(dict(self.report(launch),**patch),launch)
        for patch in ({'requestReference':self.report(3)['requestReference']},
                      {'latestResponseModel':self.protocol.MODEL},{'latestReturnedSourceSha256':'f'*64},
                      {'latestRequestSha256':'f'*64},{'latestRequestStatus':'returnedValidated'}):
            with self.subTest(patch=patch),self.assertRaises(ValueError):self.validate(dict(self.report(1),**patch))

    def test_fresh_request_reference_exact_and_distinct_from_reserved_one(self):
        for key,bad in {'version':True,'projectId':'p','sessionId':'s','number':1,'requestSha256':'e'*64}.items():
            value=self.report(3);value['requestReference'][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(value,3)
        value=self.report(3);value['latestRequestSha256']=value['unresolvedRequestSha256']
        value['requestReference']['requestSha256']=value['latestRequestSha256']
        with self.assertRaises(ValueError):self.validate(value,3)
        for patch in ({'latestResponseModel':None},{'latestReturnedSourceSha256':None},
                      {'latestRequestStatus':'reserved'},{'requestReference':None}):
            with self.subTest(patch=patch),self.assertRaises(ValueError):self.validate(dict(self.report(3),**patch),3)

    def test_exact_member_sets_for_reports_references_records_counters(self):
        for section in ('report','requestReference','recordsBefore','recordsAfter','counters'):
            for extra in (False,True):
                value=self.report(3);target=value if section=='report' else value[section]
                if extra:target['unexpected']=None
                else:target.pop(next(iter(target)))
                with self.subTest(section=section,extra=extra),self.assertRaises(ValueError):self.validate(value,3)

    def test_all_hash_fields_are_lowercase64hex_or_genuine_absence(self):
        for key in ('unresolvedRequestSha256','latestRequestSha256','originalSessionSha256',
                    'unrelatedBeforeSha256','unrelatedAfterSha256','declaredSourceSha256','latestReturnedSourceSha256'):
            for bad in (None,True,'F'*64,'g'*64,'a'*63):
                with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):self.validate(dict(self.report(3),**{key:bad}),3)

    def test_only_request_journal_can_change_at_reservation_and_fresh_return(self):
        for launch in (1,2,3,4):
            for slot in self.protocol.RECORD_SLOTS:
                value=self.report(launch);value['recordsAfter'][slot]='e'*64
                with self.subTest(launch=launch,slot=slot):
                    if slot=='requestJournal' and launch in (1,3):self.validate(value,launch)
                    else:
                        with self.assertRaises(ValueError):self.validate(value,launch)
        for launch in (1,3):
            value=self.report(launch);value['recordsAfter']['requestJournal']=value['recordsBefore']['requestJournal']
            with self.assertRaises(ValueError):self.validate(value,launch)
        value=self.report(1);value['recordsBefore']['requestJournal']='e'*64
        with self.assertRaises(ValueError):self.validate(value)

    def test_every_counter_and_unrelated_write_refused(self):
        for launch in (1,2,3,4):
            for key in self.protocol.COUNTER_KEYS:
                for bad in (True,-1,self.report(launch)['counters'][key]+1):
                    value=self.report(launch);value['counters'][key]=bad
                    with self.subTest(launch=launch,key=key,bad=bad),self.assertRaises(ValueError):self.validate(value,launch)
        with self.assertRaises(ValueError):self.validate(dict(self.report(1),unrelatedAfterSha256='e'*64))

    def test_cross_launch_pins_unknown_intent_baseline_and_cold_reference(self):
        for launch in (2,3,4):
            for change in ('unresolvedRequestSha256','declaredSourceSha256','records','unrelated'):
                value=self.report(launch)
                if change=='records':value['recordsBefore']['working']=value['recordsAfter']['working']='e'*64
                elif change=='unrelated':value['unrelatedBeforeSha256']=value['unrelatedAfterSha256']='e'*64
                else:
                    value[change]='e'*64
                    if change=='unresolvedRequestSha256' and launch==2:value['latestRequestSha256']='e'*64
                with self.subTest(launch=launch,change=change),self.assertRaises(ValueError):self.protocol.require_transition(self.report(launch-1),value)
        value=self.report(4);value['latestRequestSha256']=value['requestReference']['requestSha256']='e'*64
        with self.assertRaises(ValueError):self.protocol.require_transition(self.report(3),value)
        for previous,current in [(None,self.report(2)),(True,self.report(2)),(self.report(1),self.report(3))]:
            with self.assertRaises(ValueError):self.protocol.require_transition(previous,current)

    def test_strict_reader_duplicate_nonfinite_partial_oversize_symlink_fifo(self):
        import os
        file=self.root/'launch-1.json';raw=json.dumps(self.report(1));file.write_text(raw)
        self.protocol.read_report(self.root,1,self.nonce)
        for text in (raw.replace('"version": 24','"version":24,"version":24',1),
                     raw.replace('"setupCalls": 1','"setupCalls":1,"setupCalls":1',1),
                     raw.replace('"sessionRevision": 0','"sessionRevision":NaN'), ' '*8193):
            file.write_text(text)
            with self.assertRaises(ValueError):self.protocol.read_report(self.root,1,self.nonce)
        file.write_text('{"private":')
        with self.assertRaises(json.JSONDecodeError) as caught:self.protocol.read_report(self.root,1,self.nonce)
        self.assertEqual(caught.exception.doc,'')
        file.unlink();target=self.root/'target';target.write_text(raw);file.symlink_to(target)
        with self.assertRaises((ValueError,OSError)):self.protocol.read_report(self.root,1,self.nonce)
        file.unlink();os.mkfifo(file)
        with self.assertRaises(ValueError):self.protocol.read_report(self.root,1,self.nonce)

    def driver(self,explicit=False,bad_launch=None,exit_code=0,early=False,signal=-9,replace=False,sabotage_challenge=False):
        sdk=self.root/'sdk';(sdk/'bin/cache').mkdir(parents=True,exist_ok=True)
        (sdk/'bin/cache/flutter_tools.snapshot').write_text('prepared SDK')
        control=Path(tempfile.mkdtemp(prefix="asg-candidate-crash-driver-",dir=self.root)).resolve()
        self.driver_root=control
        processes=[];outer=self
        class Process:
            def __init__(self,*args,**kwargs):
                self.number=len(processes)+1;self.killed=False;processes.append(self)
                outer.assertEqual(args[0],[str(outer.root/'owned-executable')])
                outer.assertEqual(kwargs['env']['ASG_CANDIDATE_CRASH_ROOT'],str(control))
                value=outer.report(self.number)
                if bad_launch==self.number:value['counters']['sdkAttempts']=1
                (control/f'launch-{self.number}.json').write_text(json.dumps(value))
            def poll(self):
                return signal if self.killed else exit_code if self.number in (2,4) or early else None
            def kill(self):self.killed=True
            def wait(self,timeout):
                if sabotage_challenge and self.number==1 and self.killed:
                    target=outer.root/'outside-challenge';target.write_bytes(b'preserve unrelated bytes')
                    challenge=control/'challenge.json';challenge.unlink();challenge.symlink_to(target)
                if replace:
                    file=control/f'launch-{self.number}.json'
                    raw=file.read_text();file.unlink();file.write_text(raw)
                return self.poll()
        with mock.patch.object(self.protocol.sys,'platform','darwin'), \
                mock.patch.object(self.protocol,'inspect_bundle',return_value=(self.root/'owned-executable','a'*64)), \
                mock.patch.object(self.protocol.tempfile,'mkdtemp',return_value=str(control)), \
                mock.patch.object(self.protocol.secrets,'token_hex',return_value=self.nonce), \
                mock.patch.object(self.protocol.subprocess,'Popen',side_effect=Process):
            try:return self.protocol.run_initial_unresolved(self.root/'fixture.app',sdk,explicit),processes
            except ValueError:self.failed_processes=processes;raise

    def test_owned_two_and_four_launches_keep_explicit_next_stage_local(self):
        for explicit,count in ((False,2),(True,4)):
            value,processes=self.driver(explicit)
            self.assertEqual(len(value['launches']),count)
            self.assertEqual([p.killed for p in processes],[True,False]*(count//2))
            challenge=json.loads((self.driver_root/'challenge.json').read_text())
            self.assertEqual(set(challenge),{'mode','nonce','launch','sdk','explicitNext'})
            self.assertIs(challenge['explicitNext'],explicit)

    def test_owned_driver_refuses_report_before_launching_any_next_child(self):
        with self.assertRaises(ValueError):self.driver(True,bad_launch=2)
        self.assertEqual(len(self.failed_processes),2)
        self.assertEqual([p.killed for p in self.failed_processes],[True,False])

    def test_owned_driver_refuses_premature_exit_wrong_signal_nonzero_and_replaced_report(self):
        for options in ({'early':True},{'signal':-15},{'exit_code':1},{'replace':True}):
            with self.subTest(options=options),self.assertRaises(ValueError):self.driver(**options)

    def test_invalid_mode_and_sdk_never_launch_any_child(self):
        with mock.patch.object(self.protocol,'inspect_bundle') as inspect:
            with self.assertRaises(ValueError):self.protocol.run_initial_unresolved(self.root,self.root,1)
            inspect.assert_not_called()
        for sdk in ('relative','/bad\npath',str(self.root/'missing')):
            with mock.patch.object(self.protocol.sys,'platform','darwin'), \
                    mock.patch.object(self.protocol,'inspect_bundle',return_value=(self.root/'app','a'*64)), \
                    mock.patch.object(self.protocol.subprocess,'Popen') as launch:
                with self.assertRaises((ValueError,OSError)):self.protocol.run_initial_unresolved(self.root,sdk)
                launch.assert_not_called()

    def test_cli_explicit_mode_rejects_every_other_scenario_prelaunch(self):
        import contextlib,io
        base=['native_candidate_crash.py','--bundle','/supplied.app','--sdk','/supplied/sdk']
        flags=('--initial-lineage','--initial-retry','--initial-corrupt','--repair-lineage',
            '--lineage-retry','--lineage-corrupt','--task-decision','--stop','--precommit',
            '--running','--uncertain','--acknowledge','--retry','--promote','--promotion-crash',
            '--session-bound','--admission-crash','--session-cancel','--session-cancel-active','--session-cancel-unknown')
        bad=[['--unresolved-next']]+[['--initial-unresolved',flag] for flag in flags]
        bad += [['--initial-unresolved','--operation','test'],['--initial-unresolved','--initial-boundary','precommit'],
                ['--initial-unresolved','--lineage-boundary','postcommit'],['--initial-lineage','--unresolved-next']]
        for args in bad:
            with self.subTest(args=args),mock.patch.object(fixture.sys,'argv',base+args), \
                    mock.patch.object(self.protocol,'run_initial_unresolved') as run,contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:fixture.main()
                self.assertEqual(caught.exception.code,2);run.assert_not_called()
        with mock.patch.object(fixture.sys,'argv',base+['--initial-unresolved','--unresolved-next']), \
                mock.patch.object(self.protocol,'run_initial_unresolved',return_value={}) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            fixture.main();run.assert_called_once_with('/supplied.app','/supplied/sdk',True)


    def test_incomplete_owned_report_deadline_cleans_up_live_child(self):
        with mock.patch.object(self.protocol,'read_report',side_effect=json.JSONDecodeError('partial','',0)), \
                mock.patch.object(self.protocol.time,'monotonic',side_effect=[0,61]):
            with self.assertRaises(ValueError):self.driver()
        self.assertEqual(len(self.failed_processes),1)
        self.assertTrue(self.failed_processes[0].killed)

    def test_reader_refuses_report_replaced_between_lstat_and_open(self):
        file=self.root/'launch-1.json';file.write_text(json.dumps(self.report(1)))
        original_open=self.protocol.os.open
        def replacing_open(path,flags):
            raw=file.read_text();other=self.root/'replacement';other.write_text(raw);other.replace(file)
            return original_open(path,flags)
        with mock.patch.object(self.protocol.os,'open',side_effect=replacing_open):
            with self.assertRaises(ValueError):self.protocol.read_report(self.root,1,self.nonce)

    def test_driver_refuses_symlink_disposable_root_before_launch(self):
        sdk=self.root/'sdk';(sdk/'bin/cache').mkdir(parents=True)
        (sdk/'bin/cache/flutter_tools.snapshot').write_text('prepared SDK')
        alias=self.root/'alias';alias.symlink_to(self.root,target_is_directory=True)
        with mock.patch.object(self.protocol.sys,'platform','darwin'), \
                mock.patch.object(self.protocol,'inspect_bundle',return_value=(self.root/'app','a'*64)), \
                mock.patch.object(self.protocol.tempfile,'mkdtemp',return_value=str(alias)), \
                mock.patch.object(self.protocol.subprocess,'Popen') as launch:
            with self.assertRaises(ValueError):self.protocol.run_initial_unresolved(self.root,sdk)
            launch.assert_not_called()

    def unsafe_write_case(self, name):
        sdk=self.root/'sdk';(sdk/'bin/cache').mkdir(parents=True)
        (sdk/'bin/cache/flutter_tools.snapshot').write_text('prepared SDK')
        control=self.root/'control';control.mkdir(mode=0o700)
        target=self.root/'outside-control';target.write_bytes(b'preserve unrelated bytes')
        (control/name).symlink_to(target)
        with mock.patch.object(self.protocol.sys,'platform','darwin'), \
                mock.patch.object(self.protocol,'inspect_bundle',return_value=(self.root/'app','a'*64)), \
                mock.patch.object(self.protocol.tempfile,'mkdtemp',return_value=str(control)), \
                mock.patch.object(self.protocol.subprocess,'Popen',side_effect=ValueError('never launch in refusal test')) as launch:
            with self.assertRaises((ValueError,OSError)):
                self.protocol.run_initial_unresolved(self.root,sdk)
            self.assertEqual(target.read_bytes(),b'preserve unrelated bytes')
            launch.assert_not_called()

    def test_changed_challenge_between_owned_launches_refuses_without_touching_target(self):
        with self.assertRaises(ValueError):self.driver(sabotage_challenge=True)
        self.assertEqual((self.root/'outside-challenge').read_bytes(),b'preserve unrelated bytes')
        self.assertEqual(len(self.failed_processes),1)
        self.assertTrue(self.failed_processes[0].killed)

    def test_driver_refuses_preexisting_challenge_symlink_without_touching_target(self):
        self.unsafe_write_case('challenge.json')

    def test_driver_refuses_preexisting_log_symlink_without_touching_target(self):
        self.unsafe_write_case('process-1.log')

class InitialReturnBoundaryTests(unittest.TestCase):
    """Protocol25 does not equate stored return metadata with proposal delivery."""
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='asg-return-host-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve();self.nonce='d'*32
        self.protocol=fixture.native_initial_return_boundary

    digest=staticmethod(UnresolvedInitialTests.digest)

    def records(self,committed=False):
        value={key:None for key in self.protocol.RECORD_SLOTS}
        value.update(working=self.digest('working'),session=self.digest('raw session'),
                     requestJournal=self.digest('returned journal' if committed else 'reserved journal'))
        return value

    def report(self,launch,boundary='beforeCommit'):
        committed=boundary=='afterCommit';project=f'restart-{self.nonce}';session=f'session-{self.nonce}'
        counters={key:0 for key in self.protocol.COUNTER_KEYS}
        if launch==1:counters.update(setupCalls=1,proposalCalls=1,reservationCommits=1,reservationReturns=1,
            suppliedProviderCalls=1,terminalAttempts=1,terminalCommits=int(committed))
        return {'version':25,'mode':'initial-return-boundary','nonce':self.nonce,'launch':launch,
            'boundary':boundary,'stage':'held-terminal' if launch==1 else 'cold-retained',
            'projectId':project,'sessionId':session,'boardTaskId':'Tanalyze','requirementId':'R1',
            'requestedModel':self.protocol.MODEL,'requestCount':1,'requestNumber':1,
            'requestStatus':'returnedValidated' if committed else 'reserved',
            'requestSha256':self.digest('returned request' if committed else 'reserved request'),
            'storedResponseModel':self.protocol.MODEL if committed else None,
            'storedReturnedSourceSha256':self.digest('source map') if committed else None,
            'validatedResponseModel':self.protocol.MODEL if launch==1 else None,
            'validatedReturnedSourceSha256':self.digest('source map') if launch==1 else None,
            'originalSessionSha256':self.digest('raw session'),'sessionRevision':0,'sessionDispatchCount':0,
            'deliveredReference':None,'retainedReference':{'version':1,'projectId':project,'sessionId':session,
                'number':1,'requestSha256':self.digest('returned request')} if launch==2 and committed else None,
            'recordsBefore':dict(self.records(committed),requestJournal=None) if launch==1 else self.records(committed),'recordsAfter':self.records(committed),
            'unrelatedBeforeSha256':self.digest('unrelated'),'unrelatedAfterSha256':self.digest('unrelated'),
            'declaredSourceSha256':self.digest('declared metadata'),'counters':counters}

    def validate(self,value,launch=1,boundary='beforeCommit'):
        return self.protocol.validate_report(value,launch,self.nonce,boundary)

    def test_both_boundaries_and_independent_cold_transition_fit8192(self):
        for boundary in ('beforeCommit','afterCommit'):
            previous=None
            for launch in (1,2):
                value=self.report(launch,boundary);self.assertLess(len(json.dumps(value).encode()),8192)
                self.validate(value,launch,boundary);self.protocol.require_transition(previous,value);previous=value

    def test_strict_schema_identity_numbers_and_boundary_refusals(self):
        for key,bad in {'version':24,'mode':'initial-unresolved','nonce':'a'*32,'launch':True,
            'boundary':'precommit','stage':'read-only','projectId':'p','sessionId':'s','boardTaskId':'Ttest',
            'requirementId':'F20','requestedModel':'wrong','requestCount':True,'requestNumber':2,
            'sessionRevision':1,'sessionDispatchCount':True}.items():
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(dict(self.report(1),**{key:bad}))
        for section in ('report','retainedReference','recordsBefore','recordsAfter','counters'):
            for extra in (False,True):
                value=self.report(2,'afterCommit');target=value if section=='report' else value[section]
                if extra:target['unknown']=None
                else:target.pop(next(iter(target)))
                with self.subTest(section=section,extra=extra),self.assertRaises(ValueError):self.validate(value,2,'afterCommit')
        for launch in (True,0,3):
            with self.assertRaises(ValueError):self.protocol.validate_report(self.report(1),launch,self.nonce,'beforeCommit')

    def test_stored_validated_and_delivered_are_distinct(self):
        for boundary in ('beforeCommit','afterCommit'):
            for launch in (1,2):
                value=self.report(launch,boundary)
                for patch in ({'deliveredReference':{}},{'validatedResponseModel':'wrong'},
                              {'validatedReturnedSourceSha256':'e'*64},{'storedResponseModel':'wrong'},
                              {'storedReturnedSourceSha256':'e'*64}):
                    # A cold afterCommit standalone hash is an opaque observation; transition pins it.
                    if ((launch==2 and boundary=='afterCommit' and set(patch)=={'storedReturnedSourceSha256'}) or
                            (launch==1 and boundary=='beforeCommit' and set(patch)=={'validatedReturnedSourceSha256'})):continue
                    with self.subTest(launch=launch,boundary=boundary,patch=patch),self.assertRaises(ValueError):
                        self.validate(dict(value,**patch),launch,boundary)
        value=self.report(1,'afterCommit');value['retainedReference']=self.report(2,'afterCommit')['retainedReference']
        with self.assertRaises(ValueError):self.validate(value,1,'afterCommit')
        value=self.report(2);value['retainedReference']={}
        with self.assertRaises(ValueError):self.validate(value,2)
        for key,bad in {'version':True,'projectId':'p','sessionId':'s','number':2,'requestSha256':'f'*64}.items():
            value=self.report(2,'afterCommit');value['retainedReference'][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(value,2,'afterCommit')

    def test_record_cohort_and_cold_no_write(self):
        for boundary in ('beforeCommit','afterCommit'):
            for launch in (1,2):
                for slot in self.protocol.RECORD_SLOTS:
                    value=self.report(launch,boundary);value['recordsAfter'][slot]='e'*64
                    with self.subTest(boundary=boundary,launch=launch,slot=slot):
                        if launch==1 and slot=='requestJournal':self.validate(value,launch,boundary)
                        else:
                            with self.assertRaises(ValueError):self.validate(value,launch,boundary)
        value=self.report(1,'afterCommit');value['recordsAfter']['requestJournal']=value['recordsBefore']['requestJournal']
        with self.assertRaises(ValueError):self.validate(value,1,'afterCommit')
        value=self.report(1);value['recordsAfter']['requestJournal']=None
        with self.assertRaises(ValueError):self.validate(value)
        value=self.report(1);value['recordsBefore']['requestJournal']='e'*64
        with self.assertRaises(ValueError):self.validate(value)

    def test_all_counters_and_hash_types_are_strict(self):
        for boundary in ('beforeCommit','afterCommit'):
            for launch in (1,2):
                for key in self.protocol.COUNTER_KEYS:
                    for bad in (True,-1,self.report(launch,boundary)['counters'][key]+1):
                        value=self.report(launch,boundary);value['counters'][key]=bad
                        with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):self.validate(value,launch,boundary)
        for key in ('requestSha256','originalSessionSha256','unrelatedBeforeSha256','unrelatedAfterSha256',
                    'declaredSourceSha256','validatedReturnedSourceSha256'):
            for bad in (None,True,'F'*64,'g'*64,'a'*63):
                with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):self.validate(dict(self.report(1),**{key:bad}))

    def test_cold_transition_pins_retained_request_and_baseline(self):
        for boundary in ('beforeCommit','afterCommit'):
            for field in ('requestSha256','declaredSourceSha256','records','unrelated','boundary'):
                value=self.report(2,boundary)
                if field=='records':value['recordsBefore']['working']=value['recordsAfter']['working']='e'*64
                elif field=='unrelated':value['unrelatedBeforeSha256']=value['unrelatedAfterSha256']='e'*64
                elif field=='boundary':value['boundary']='afterCommit' if boundary=='beforeCommit' else 'beforeCommit'
                else:
                    value[field]='e'*64
                    if field=='requestSha256' and boundary=='afterCommit':value['retainedReference']['requestSha256']='e'*64
                with self.subTest(boundary=boundary,field=field),self.assertRaises(ValueError):self.protocol.require_transition(self.report(1,boundary),value)
        value=self.report(2,'afterCommit');value['storedReturnedSourceSha256']='e'*64
        with self.assertRaises(ValueError):self.protocol.require_transition(self.report(1,'afterCommit'),value)
        with self.assertRaises(ValueError):self.protocol.require_transition(None,self.report(2))

    def test_strict_control_files_refuse_symlink_duplicate_nonfinite_partial_oversize(self):
        import os
        file=self.root/'launch-1.json';raw=json.dumps(self.report(1))
        for text in (raw.replace('"version": 25','"version":25,"version":25',1),
                     raw.replace('"setupCalls": 1','"setupCalls":1,"setupCalls":1',1),
                     raw.replace('"sessionRevision": 0','"sessionRevision":NaN'), ' '*8193):
            file.write_text(text)
            with self.assertRaises(ValueError):self.protocol.read_report(self.root,1,self.nonce,'beforeCommit')
        file.write_text('{"private":')
        with self.assertRaises(json.JSONDecodeError) as caught:self.protocol.read_report(self.root,1,self.nonce,'beforeCommit')
        self.assertEqual(caught.exception.doc,'')
        file.unlink();target=self.root/'target';target.write_text(raw);file.symlink_to(target)
        with self.assertRaises((ValueError,OSError)):self.protocol.read_report(self.root,1,self.nonce,'beforeCommit')
        file.unlink();os.mkfifo(file)
        with self.assertRaises(ValueError):self.protocol.read_report(self.root,1,self.nonce,'beforeCommit')
        target=self.root/'outside';target.write_text('unchanged');(self.root/'challenge.json').symlink_to(target)
        with self.assertRaises(ValueError):self.protocol._write_challenge(self.root,1,b'{}',None)
        self.assertEqual(target.read_text(),'unchanged')

    def driver(self,boundary='beforeCommit',bad_launch=None,early=False,exit_code=0,signal=-9,tamper=None):
        sdk=self.root/'sdk';(sdk/'bin/cache').mkdir(parents=True,exist_ok=True)
        (sdk/'bin/cache/flutter_tools.snapshot').write_text('prepared SDK')
        processes=[];outer=self
        class Process:
            def __init__(self,*args,**kwargs):
                self.number=len(processes)+1;self.killed=False;processes.append(self)
                outer.assertEqual(args[0],[str(outer.root/'owned-executable')])
                outer.assertEqual(kwargs['env']['ASG_CANDIDATE_CRASH_ROOT'],str(outer.root))
                value=outer.report(self.number,boundary)
                if bad_launch==self.number:value['counters']['sdkAttempts']=1
                (outer.root/f'launch-{self.number}.json').write_text(json.dumps(value))
                if tamper=='challenge':(outer.root/'challenge.json').write_text('{}')
            def poll(self):return signal if self.killed else exit_code if self.number==2 or early else None
            def kill(self):self.killed=True
            def wait(self,timeout):
                if tamper=='report':
                    file=outer.root/f'launch-{self.number}.json';raw=file.read_text();file.unlink();file.write_text(raw)
                return self.poll()
        with mock.patch.object(self.protocol.sys,'platform','darwin'), \
                mock.patch.object(self.protocol,'inspect_bundle',return_value=(self.root/'owned-executable','a'*64)), \
                mock.patch.object(self.protocol.tempfile,'mkdtemp',return_value=str(self.root)), \
                mock.patch.object(self.protocol.secrets,'token_hex',return_value=self.nonce), \
                mock.patch.object(self.protocol.subprocess,'Popen',side_effect=Process):
            try:return self.protocol.run_initial_return_boundary(self.root/'fixture.app',sdk,boundary),processes
            except ValueError:self.failed_processes=processes;raise

    def test_owned_driver_both_boundaries_two_child_handles(self):
        for boundary in ('beforeCommit','afterCommit'):
            for file in self.root.glob('*'):
                if file.is_file():file.unlink()
            value,processes=self.driver(boundary)
            self.assertEqual([p.killed for p in processes],[True,False])
            self.assertEqual(value['version'],25)
            challenge=json.loads((self.root/'challenge.json').read_text())
            self.assertEqual(set(challenge),{'mode','nonce','launch','sdk','boundary'})
            self.assertEqual(challenge['boundary'],boundary)

    def test_owned_driver_refuses_bad_child_state_and_control_replacement(self):
        for options in ({'bad_launch':1},{'early':True},{'exit_code':1},{'signal':-15},
                        {'tamper':'report'},{'tamper':'challenge'}):
            for file in self.root.glob('*'):
                if file.is_file():file.unlink()
            with self.subTest(options=options),self.assertRaises(ValueError):self.driver(**options)

    def test_partial_deadline_cleans_up_only_owned_live_handle(self):
        with mock.patch.object(self.protocol,'read_report',side_effect=json.JSONDecodeError('partial','',0)), \
                mock.patch.object(self.protocol.time,'monotonic',side_effect=[0,61]):
            with self.assertRaises(ValueError):self.driver()
        self.assertEqual(len(self.failed_processes),1);self.assertTrue(self.failed_processes[0].killed)

    def test_cli_explicit_boundary_refuses_legacy_and_standalone_flags(self):
        import contextlib,io
        base=['native_candidate_crash.py','--bundle','/supplied.app','--sdk','/supplied/sdk']
        flags=('--initial-unresolved','--unresolved-next','--initial-lineage','--initial-retry','--initial-corrupt',
            '--repair-lineage','--lineage-retry','--lineage-corrupt','--task-decision','--stop','--precommit',
            '--running','--uncertain','--acknowledge','--retry','--promote','--promotion-crash','--session-bound',
            '--admission-crash','--session-cancel','--session-cancel-active','--session-cancel-unknown')
        bad=[['--return-boundary','beforeCommit']]+[['--initial-return-boundary',flag] for flag in flags]
        bad += [['--initial-return-boundary','--operation','test'],['--initial-return-boundary','--initial-boundary','precommit'],
                ['--initial-return-boundary','--lineage-boundary','postcommit'],['--initial-lineage','--return-boundary','afterCommit']]
        for args in bad:
            with self.subTest(args=args),mock.patch.object(fixture.sys,'argv',base+args), \
                    mock.patch.object(self.protocol,'run_initial_return_boundary') as run,contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:fixture.main()
                self.assertEqual(caught.exception.code,2);run.assert_not_called()
        for options,boundary in (([],'beforeCommit'),(['--return-boundary','afterCommit'],'afterCommit')):
            with mock.patch.object(fixture.sys,'argv',base+['--initial-return-boundary']+options), \
                    mock.patch.object(self.protocol,'run_initial_return_boundary',return_value={}) as run, \
                    contextlib.redirect_stdout(io.StringIO()):
                fixture.main();run.assert_called_once_with('/supplied.app','/supplied/sdk',boundary)


    def test_stale_report_and_invalid_boundary_refuse_before_child_launch(self):
        with mock.patch.object(self.protocol,'inspect_bundle') as inspect:
            with self.assertRaises(ValueError):self.protocol.run_initial_return_boundary(self.root,self.root,'precommit')
            inspect.assert_not_called()
        (self.root/'launch-1.json').write_text(json.dumps(self.report(1)))
        with mock.patch.object(self.protocol.subprocess,'Popen') as process:
            with self.assertRaises(ValueError):self.driver()
            process.assert_not_called()
        self.assertEqual(self.failed_processes,[])

    def test_control_link_and_replacement_preserve_external_target(self):
        target=self.root/'external';target.write_text('unchanged')
        identity=self.protocol._write_challenge(self.root,1,b'{}',None)
        challenge=self.root/'challenge.json';challenge.unlink();challenge.symlink_to(target)
        with self.assertRaises(ValueError):self.protocol._write_challenge(self.root,2,b'{}',identity)
        self.assertEqual(target.read_text(),'unchanged')
        challenge.unlink();(self.root/'challenge-2.tmp').symlink_to(target)
        with self.assertRaises(OSError):self.protocol._write_challenge(self.root,2,b'{}',None)
        self.assertEqual(target.read_text(),'unchanged')

class RepairReturnBoundaryTests(unittest.TestCase):
    """Protocol26 does not equate stored return metadata with proposal delivery."""
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(prefix='asg-return-host-tests-')
        self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name).resolve();self.nonce='d'*32
        self.protocol=fixture.native_repair_return_boundary

    digest=staticmethod(UnresolvedInitialTests.digest)

    def records(self,committed=False):
        value={key:None for key in self.protocol.RECORD_SLOTS}
        value.update(working=self.digest('working'),session=self.digest('raw session'),
                     failureJournal=self.digest('whole failure journal'),failedCandidate=self.digest('failed candidate'),
                     repairOrigin=self.digest('canonical raw origin'),
                     repairJournal=self.digest('proposed journal' if committed else 'reserved journal'))
        return value

    def report(self,launch,boundary='beforeCommit'):
        committed=boundary=='afterCommit';project=f'restart-{self.nonce}';session=f'session-{self.nonce}'
        counters={key:0 for key in self.protocol.COUNTER_KEYS}
        if launch==1:counters.update(setupCalls=1,failureSetupCalls=1,proposalCalls=1,reservationCommits=1,reservationReturns=1,
            suppliedProviderCalls=1,terminalAttempts=1,terminalCommits=int(committed))
        return {'version':26,'mode':'repair-return-boundary','nonce':self.nonce,'launch':launch,
            'boundary':boundary,'stage':'held-terminal' if launch==1 else 'cold-retained',
            'projectId':project,'sessionId':session,'boardTaskId':'Tanalyze','requirementId':'R1',
            'requestedModel':self.protocol.MODEL,'attemptCount':1,'attemptNumber':1,
            'attemptStatus':'proposed' if committed else 'reserved',
            'attemptSha256':self.digest('proposed attempt' if committed else 'reserved attempt'),
            'originSha256':self.digest('canonical raw origin'),'failureSha256':self.digest('canonical failed run'),
            'storedResponseModel':self.protocol.MODEL if committed else None,
            'storedProposalSha256':self.digest('source map') if committed else None,
            'validatedResponseModel':self.protocol.MODEL if launch==1 else None,
            'validatedProposalSha256':self.digest('source map') if launch==1 else None,
            'originalSessionSha256':self.digest('raw session'),'sessionRevision':0,'sessionDispatchCount':0,
            'deliveredReference':None,'retainedReference':{'version':1,'projectId':project,'attemptNumber':1,
                'attemptSha256':self.digest('proposed attempt'),'originSha256':self.digest('canonical raw origin')} if launch==2 and committed else None,
            'recordsBefore':dict(self.records(committed),repairJournal=None,repairOrigin=None) if launch==1 else self.records(committed),'recordsAfter':self.records(committed),
            'unrelatedBeforeSha256':self.digest('unrelated'),'unrelatedAfterSha256':self.digest('unrelated'),
            'declaredSourceSha256':self.digest('declared metadata'),'counters':counters}

    def validate(self,value,launch=1,boundary='beforeCommit'):
        return self.protocol.validate_report(value,launch,self.nonce,boundary)

    def test_both_boundaries_and_independent_cold_transition_fit8192(self):
        for boundary in ('beforeCommit','afterCommit'):
            previous=None
            for launch in (1,2):
                value=self.report(launch,boundary);self.assertLess(len(json.dumps(value).encode()),8192)
                self.validate(value,launch,boundary);self.protocol.require_transition(previous,value);previous=value

    def test_strict_schema_identity_numbers_and_boundary_refusals(self):
        for key,bad in {'version':25,'mode':'initial-unresolved','nonce':'a'*32,'launch':True,
            'boundary':'precommit','stage':'read-only','projectId':'p','sessionId':'s','boardTaskId':'Ttest',
            'requirementId':'F20','requestedModel':'wrong','attemptCount':True,'attemptNumber':2,
            'sessionRevision':1,'sessionDispatchCount':True}.items():
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(dict(self.report(1),**{key:bad}))
        for section in ('report','retainedReference','recordsBefore','recordsAfter','counters'):
            for extra in (False,True):
                value=self.report(2,'afterCommit');target=value if section=='report' else value[section]
                if extra:target['unknown']=None
                else:target.pop(next(iter(target)))
                with self.subTest(section=section,extra=extra),self.assertRaises(ValueError):self.validate(value,2,'afterCommit')
        for launch in (True,0,3):
            with self.assertRaises(ValueError):self.protocol.validate_report(self.report(1),launch,self.nonce,'beforeCommit')

    def test_stored_validated_and_delivered_are_distinct(self):
        for boundary in ('beforeCommit','afterCommit'):
            for launch in (1,2):
                value=self.report(launch,boundary)
                for patch in ({'deliveredReference':{}},{'validatedResponseModel':'wrong'},
                              {'validatedProposalSha256':'e'*64},{'storedResponseModel':'wrong'},
                              {'storedProposalSha256':'e'*64}):
                    # A cold afterCommit standalone hash is an opaque observation; transition pins it.
                    if ((launch==2 and boundary=='afterCommit' and set(patch)=={'storedProposalSha256'}) or
                            (launch==1 and boundary=='beforeCommit' and set(patch)=={'validatedProposalSha256'})):continue
                    with self.subTest(launch=launch,boundary=boundary,patch=patch),self.assertRaises(ValueError):
                        self.validate(dict(value,**patch),launch,boundary)
        value=self.report(1,'afterCommit');value['retainedReference']=self.report(2,'afterCommit')['retainedReference']
        with self.assertRaises(ValueError):self.validate(value,1,'afterCommit')
        value=self.report(2);value['retainedReference']={}
        with self.assertRaises(ValueError):self.validate(value,2)
        for key,bad in {'version':True,'projectId':'p','attemptNumber':2,'attemptSha256':'f'*64,'originSha256':'f'*64}.items():
            value=self.report(2,'afterCommit');value['retainedReference'][key]=bad
            with self.subTest(key=key),self.assertRaises(ValueError):self.validate(value,2,'afterCommit')

    def test_record_cohort_and_cold_no_write(self):
        for boundary in ('beforeCommit','afterCommit'):
            for launch in (1,2):
                for slot in self.protocol.RECORD_SLOTS:
                    value=self.report(launch,boundary);value['recordsAfter'][slot]='e'*64
                    with self.subTest(boundary=boundary,launch=launch,slot=slot):
                        if launch==1 and slot=='repairJournal':self.validate(value,launch,boundary)
                        else:
                            with self.assertRaises(ValueError):self.validate(value,launch,boundary)
        value=self.report(1,'afterCommit');value['recordsAfter']['repairJournal']=value['recordsBefore']['repairJournal']
        with self.assertRaises(ValueError):self.validate(value,1,'afterCommit')
        value=self.report(1);value['recordsAfter']['repairJournal']=None
        with self.assertRaises(ValueError):self.validate(value)
        value=self.report(1);value['recordsBefore']['repairJournal']='e'*64
        with self.assertRaises(ValueError):self.validate(value)

    def test_all_counters_and_hash_types_are_strict(self):
        for boundary in ('beforeCommit','afterCommit'):
            for launch in (1,2):
                for key in self.protocol.COUNTER_KEYS:
                    for bad in (True,-1,self.report(launch,boundary)['counters'][key]+1):
                        value=self.report(launch,boundary);value['counters'][key]=bad
                        with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):self.validate(value,launch,boundary)
        for key in ('attemptSha256','originSha256','failureSha256','originalSessionSha256','unrelatedBeforeSha256','unrelatedAfterSha256',
                    'declaredSourceSha256','validatedProposalSha256'):
            for bad in (None,True,'F'*64,'g'*64,'a'*63):
                with self.subTest(key=key,bad=bad),self.assertRaises(ValueError):self.validate(dict(self.report(1),**{key:bad}))

    def test_cold_transition_pins_retained_request_and_baseline(self):
        for boundary in ('beforeCommit','afterCommit'):
            for field in ('attemptSha256','declaredSourceSha256','records','unrelated','boundary'):
                value=self.report(2,boundary)
                if field=='records':value['recordsBefore']['working']=value['recordsAfter']['working']='e'*64
                elif field=='unrelated':value['unrelatedBeforeSha256']=value['unrelatedAfterSha256']='e'*64
                elif field=='boundary':value['boundary']='afterCommit' if boundary=='beforeCommit' else 'beforeCommit'
                else:
                    value[field]='e'*64
                    if field=='attemptSha256' and boundary=='afterCommit':value['retainedReference']['attemptSha256']='e'*64
                with self.subTest(boundary=boundary,field=field),self.assertRaises(ValueError):self.protocol.require_transition(self.report(1,boundary),value)
        value=self.report(2,'afterCommit');value['storedProposalSha256']='e'*64
        with self.assertRaises(ValueError):self.protocol.require_transition(self.report(1,'afterCommit'),value)
        with self.assertRaises(ValueError):self.protocol.require_transition(None,self.report(2))

    def test_strict_control_files_refuse_symlink_duplicate_nonfinite_partial_oversize(self):
        import os
        file=self.root/'launch-1.json';raw=json.dumps(self.report(1))
        for text in (raw.replace('"version": 26','"version":26,"version":26',1),
                     raw.replace('"setupCalls": 1','"setupCalls":1,"setupCalls":1',1),
                     raw.replace('"sessionRevision": 0','"sessionRevision":NaN'), '['*1100+'0'+']'*1100, ' '*8193):
            file.write_text(text)
            with self.assertRaises(ValueError):self.protocol.read_report(self.root,1,self.nonce,'beforeCommit')
        file.write_text('{"private":')
        with self.assertRaises(json.JSONDecodeError) as caught:self.protocol.read_report(self.root,1,self.nonce,'beforeCommit')
        self.assertEqual(caught.exception.doc,'')
        file.unlink();target=self.root/'target';target.write_text(raw);file.symlink_to(target)
        with self.assertRaises((ValueError,OSError)):self.protocol.read_report(self.root,1,self.nonce,'beforeCommit')
        file.unlink();os.mkfifo(file)
        with self.assertRaises(ValueError):self.protocol.read_report(self.root,1,self.nonce,'beforeCommit')
        target=self.root/'outside';target.write_text('unchanged');(self.root/'challenge.json').symlink_to(target)
        with self.assertRaises(ValueError):self.protocol._write_challenge(self.root,1,b'{}',None)
        self.assertEqual(target.read_text(),'unchanged')

    def driver(self,boundary='beforeCommit',bad_launch=None,early=False,exit_code=0,signal=-9,tamper=None):
        sdk=self.root/'sdk';(sdk/'bin/cache').mkdir(parents=True,exist_ok=True)
        (sdk/'bin/cache/flutter_tools.snapshot').write_text('prepared SDK')
        processes=[];outer=self
        class Process:
            def __init__(self,*args,**kwargs):
                self.number=len(processes)+1;self.killed=False;processes.append(self)
                outer.assertEqual(args[0],[str(outer.root/'owned-executable')])
                outer.assertEqual(kwargs['env']['ASG_CANDIDATE_CRASH_ROOT'],str(outer.root))
                value=outer.report(self.number,boundary)
                if bad_launch==self.number:value['counters']['sdkAttempts']=1
                (outer.root/f'launch-{self.number}.json').write_text(json.dumps(value))
                if tamper=='challenge':(outer.root/'challenge.json').write_text('{}')
            def poll(self):return signal if self.killed else exit_code if self.number==2 or early else None
            def kill(self):self.killed=True
            def wait(self,timeout):
                if tamper=='report':
                    file=outer.root/f'launch-{self.number}.json';raw=file.read_text();file.unlink();file.write_text(raw)
                return self.poll()
        with mock.patch.object(self.protocol.sys,'platform','darwin'), \
                mock.patch.object(self.protocol,'inspect_bundle',return_value=(self.root/'owned-executable','a'*64)), \
                mock.patch.object(self.protocol.tempfile,'mkdtemp',return_value=str(self.root)), \
                mock.patch.object(self.protocol.secrets,'token_hex',return_value=self.nonce), \
                mock.patch.object(self.protocol.subprocess,'Popen',side_effect=Process):
            try:return self.protocol.run_repair_return_boundary(self.root/'fixture.app',sdk,boundary),processes
            except ValueError:self.failed_processes=processes;raise

    def test_owned_driver_both_boundaries_two_child_handles(self):
        for boundary in ('beforeCommit','afterCommit'):
            for file in self.root.glob('*'):
                if file.is_file():file.unlink()
            value,processes=self.driver(boundary)
            self.assertEqual([p.killed for p in processes],[True,False])
            self.assertEqual(value['version'],26)
            challenge=json.loads((self.root/'challenge.json').read_text())
            self.assertEqual(set(challenge),{'mode','nonce','launch','sdk','boundary'})
            self.assertEqual(challenge['boundary'],boundary)

    def test_owned_driver_refuses_bad_child_state_and_control_replacement(self):
        for options in ({'bad_launch':1},{'early':True},{'exit_code':1},{'signal':-15},
                        {'tamper':'report'},{'tamper':'challenge'}):
            for file in self.root.glob('*'):
                if file.is_file():file.unlink()
            with self.subTest(options=options),self.assertRaises(ValueError):self.driver(**options)

    def test_partial_deadline_cleans_up_only_owned_live_handle(self):
        with mock.patch.object(self.protocol,'read_report',side_effect=json.JSONDecodeError('partial','',0)), \
                mock.patch.object(self.protocol.time,'monotonic',side_effect=[0,61]):
            with self.assertRaises(ValueError):self.driver()
        self.assertEqual(len(self.failed_processes),1);self.assertTrue(self.failed_processes[0].killed)

    def test_cli_explicit_boundary_refuses_legacy_and_standalone_flags(self):
        import contextlib,io
        base=['native_candidate_crash.py','--bundle','/supplied.app','--sdk','/supplied/sdk']
        flags=('--initial-return-boundary','--initial-unresolved','--unresolved-next','--initial-lineage','--initial-retry','--initial-corrupt',
            '--repair-lineage','--lineage-retry','--lineage-corrupt','--task-decision','--stop','--precommit',
            '--running','--uncertain','--acknowledge','--retry','--promote','--promotion-crash','--session-bound',
            '--admission-crash','--session-cancel','--session-cancel-active','--session-cancel-unknown')
        bad=[['--return-boundary','beforeCommit']]+[['--repair-return-boundary',flag] for flag in flags]
        bad += [['--repair-return-boundary','--operation','test'],['--repair-return-boundary','--initial-boundary','precommit'],
                ['--repair-return-boundary','--lineage-boundary','postcommit'],['--repair-return-boundary','--initial-return-boundary']]
        for args in bad:
            with self.subTest(args=args),mock.patch.object(fixture.sys,'argv',base+args), \
                    mock.patch.object(self.protocol,'run_repair_return_boundary') as run,contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit) as caught:fixture.main()
                self.assertEqual(caught.exception.code,2);run.assert_not_called()
        for options,boundary in (([],'beforeCommit'),(['--return-boundary','afterCommit'],'afterCommit')):
            with mock.patch.object(fixture.sys,'argv',base+['--repair-return-boundary']+options), \
                    mock.patch.object(self.protocol,'run_repair_return_boundary',return_value={}) as run, \
                    contextlib.redirect_stdout(io.StringIO()):
                fixture.main();run.assert_called_once_with('/supplied.app','/supplied/sdk',boundary)


    def test_stale_report_and_invalid_boundary_refuse_before_child_launch(self):
        with mock.patch.object(self.protocol,'inspect_bundle') as inspect:
            with self.assertRaises(ValueError):self.protocol.run_repair_return_boundary(self.root,self.root,'precommit')
            inspect.assert_not_called()
        (self.root/'launch-1.json').write_text(json.dumps(self.report(1)))
        with mock.patch.object(self.protocol.subprocess,'Popen') as process:
            with self.assertRaises(ValueError):self.driver()
            process.assert_not_called()
        self.assertEqual(self.failed_processes,[])

    def test_control_link_and_replacement_preserve_external_target(self):
        target=self.root/'external';target.write_text('unchanged')
        identity=self.protocol._write_challenge(self.root,1,b'{}',None)
        challenge=self.root/'challenge.json';challenge.unlink();challenge.symlink_to(target)
        with self.assertRaises(ValueError):self.protocol._write_challenge(self.root,2,b'{}',identity)
        self.assertEqual(target.read_text(),'unchanged')
        challenge.unlink();(self.root/'challenge-2.tmp').symlink_to(target)
        with self.assertRaises(OSError):self.protocol._write_challenge(self.root,2,b'{}',None)
        self.assertEqual(target.read_text(),'unchanged')


    def test_origin_and_failed_baseline_cohort_are_exactly_pinned(self):
        for boundary in ('beforeCommit','afterCommit'):
            for key in ('repairOrigin','repairJournal'):
                value=self.report(1,boundary);value['recordsBefore'][key]='e'*64
                with self.subTest(boundary=boundary,key=key),self.assertRaises(ValueError):self.validate(value,1,boundary)
                value=self.report(1,boundary);value['recordsAfter'][key]=None
                with self.assertRaises(ValueError):self.validate(value,1,boundary)
            value=self.report(1,boundary);value['originSha256']='e'*64
            with self.assertRaises(ValueError):self.validate(value,1,boundary)
            for field in ('failureSha256','originSha256'):
                value=self.report(2,boundary);value[field]='e'*64
                if field=='originSha256':
                    value['recordsBefore']['repairOrigin']=value['recordsAfter']['repairOrigin']='e'*64
                    if boundary=='afterCommit':value['retainedReference']['originSha256']='e'*64
                with self.subTest(boundary=boundary,field=field),self.assertRaises(ValueError):
                    self.protocol.require_transition(self.report(1,boundary),value)
        self.assertNotEqual(self.report(1)['failureSha256'],self.report(1)['recordsAfter']['failureJournal'])

if __name__ == '__main__':
    unittest.main()
