# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Crash/reopen only a verified disposable native candidate fixture; never builds or installs."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time

from native_restart_probe import inspect_bundle
import native_repair_lineage
import native_initial_lineage
import native_initial_unresolved
import native_initial_return_boundary
import native_repair_return_boundary

OPERATIONS = ['resolve', 'analyze', 'test', 'build']


def read_session_proof(value, nonce, launch, admission_crash=False, session_cancel=False, session_cancel_active=False, session_cancel_unknown=False):
    """Validate fixed session evidence; this never authorizes or launches work."""
    keys = {'sessionId', 'projectId', 'revision', 'dispatchId', 'dispatchCount',
            'sessionSha256', 'journalSha256', 'candidateSha256', 'executionSha256',
            'receiptPreparations', 'commandEntries', 'taskHistory', 'reopenContextSha256', 'reopenEntryChecked', 'reopenEntryAvailable'}
    if session_cancel:
        keys |= {'cancellationRequested', 'receiptSha256'}
    if session_cancel_active:
        keys.add('activeBoundarySha256')
    if session_cancel_unknown:
        keys |= {'publicationFaultSha256', 'testResultPresent'}
    if (not isinstance(value, dict) or set(value) != keys or
            not isinstance(nonce, str) or re.fullmatch(r'[a-f0-9]{32}', nonce) is None or
            type(launch) is not int or launch not in (1, 2) or
            type(admission_crash) is not bool or type(session_cancel) is not bool or
            type(session_cancel_active) is not bool or (session_cancel_active and not session_cancel) or
            type(session_cancel_unknown) is not bool or (session_cancel_unknown and not session_cancel_active) or
            (session_cancel and admission_crash) or
            value.get('sessionId') != f'session-{nonce}' or
            value.get('projectId') != f'restart-{nonce}'):
        raise ValueError('Session evidence identity mismatch')
    admitted = not admission_crash
    expected_counts = {'revision': 2 if session_cancel else int(admitted), 'dispatchCount': int(admitted),
                       'receiptPreparations': int(admitted and launch == 1),
                       'commandEntries': (1 if session_cancel and not session_cancel_active else 3) if admitted and launch == 1 else 0}
    if (any(type(value.get(key)) is not int or value[key] != count
            for key, count in expected_counts.items()) or
            value.get('dispatchId') != (f'candidate-restart-{nonce}-1:3' if admitted else None)):
        raise ValueError('Session admission or no-replay evidence mismatch')
    if (value.get('reopenEntryChecked') is not (launch == 2) or
            value.get('reopenEntryAvailable') is not (launch == 2 and admitted and not session_cancel)):
        raise ValueError('Production reopen entry observation mismatch')
    if session_cancel_unknown and value.get('testResultPresent') is not False:
        raise ValueError('Unknown test result was replaced by completion evidence')
    if session_cancel and value.get('cancellationRequested') is not True:
        raise ValueError('Session cancellation intent missing')
    for key in ('sessionSha256', 'journalSha256', 'candidateSha256', 'executionSha256', 'reopenContextSha256') + (('receiptSha256',) if session_cancel else ()) + (('activeBoundarySha256',) if session_cancel_active else ()) + (('publicationFaultSha256',) if session_cancel_unknown else ()):
        fingerprint = value.get(key)
        if key != 'sessionSha256' and not admitted:
            if fingerprint is not None:
                raise ValueError('Uncommitted startup record was retained')
        elif not isinstance(fingerprint, str) or re.fullmatch(r'[a-f0-9]{64}', fingerprint) is None:
            raise ValueError('Session record fingerprint missing')
    read_task_history(value['taskHistory'], admitted, session_cancel, session_cancel_active, session_cancel_unknown)
    return value


def read_task_history(proof, admitted, cancelled=False, active=False, unknown=False):
    """Validate fixed observation rows, never interpret them as task completion."""
    if not admitted:
        if proof is not None:
            raise ValueError('Unadmitted task history present')
        return
    keys = {'sha256', 'projectionSha256', 'events', 'withdrawalSequence', 'pendingOperation', 'finished'}
    if not isinstance(proof, dict) or set(proof) != keys:
        raise ValueError('Task history proof missing')
    fingerprint = proof.get('sha256')
    if (not isinstance(fingerprint, str) or re.fullmatch(r'[a-f0-9]{64}', fingerprint) is None or
            proof.get('projectionSha256') != fingerprint):
        raise ValueError('Task history projection mismatch')
    events = [['admitted', None, None, None]]
    for operation in OPERATIONS[:1 if cancelled and not active else 2]:
        events += [['pending', operation, None, None], ['result', operation, 0, False]]
    if not cancelled or active:
        events += [['pending', 'test', None, None]]
    if cancelled:
        events += ([['interrupted', 'test', None, None]] if unknown else
                   ([['result', 'test', 0, False]] if active else []) + [['finished', None, None, None]])
    # JSON comparison keeps booleans distinct from integer exits/sequences.
    if json.dumps(proof.get('events'), separators=(',', ':')) != json.dumps(events, separators=(',', ':')):
        raise ValueError('Task history event sequence mismatch')
    boundary = 6 if active else 2 if cancelled else None
    if (type(proof.get('withdrawalSequence')) is not type(boundary) or proof['withdrawalSequence'] != boundary or
            proof.get('pendingOperation') != ('test' if not cancelled or unknown else None) or
            proof.get('finished') is not (cancelled and not unknown)):
        raise ValueError('Task history unknown or withdrawal mismatch')


def retry_digest(proof):
    stable = {key: value for key, value in proof.items()
              if key not in ('receiptPreparations', 'commandEntries', 'reopenEntryChecked', 'reopenEntryAvailable')}
    return hashlib.sha256(json.dumps(stable, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def read_retry_proof(proof, nonce, launch, promote=False):
    stages = (1, 2, 3, 4, 5) if promote else (1, 2, 3, 4)
    if type(promote) is not bool or type(launch) is not int or launch not in stages:
        raise ValueError('Invalid retry proof stage')
    hashes = {'basisSha256', 'sessionSha256', 'journalSha256', 'candidateSha256',
              'firstRunSha256', 'firstExecutionSha256', 'firstReceiptSha256', 'stopSha256',
              'recoverySha256', 'secondExecutionSha256', 'secondReceiptSha256'}
    keys = hashes | {'sessionId', 'projectId', 'revision', 'dispatchCount', 'dispatchIds',
                     'cancellationRequested', 'receiptPreparations', 'commandEntries', 'taskHistories', 'reopenEntryChecked', 'reopenEntryAvailable'}
    if promote:
        keys |= {'workingSha256', 'previousSha256', 'workingPublished', 'secondExecutionPhase', 'publication'}
    count = 2 if launch >= 3 else 1
    if (not isinstance(proof, dict) or set(proof) != keys or type(launch) is not int or
            launch not in stages or not isinstance(nonce, str) or
            re.fullmatch(r'[a-f0-9]{32}', nonce) is None or
            proof.get('sessionId') != f'session-{nonce}' or proof.get('projectId') != f'restart-{nonce}' or
            proof.get('cancellationRequested') is not False or
            proof.get('dispatchIds') != [f'candidate-restart-{nonce}-{number}:3' for number in range(1, count + 1)]):
        raise ValueError('Bound retry session identity mismatch')
    counts = {'revision': count, 'dispatchCount': count,
              'receiptPreparations': int(launch in (1, 3)),
              'commandEntries': 3 if launch == 1 else 4 if launch == 3 else 0}
    if any(type(proof.get(key)) is not int or proof[key] != value for key, value in counts.items()):
        raise ValueError('Bound retry admission or no-replay count mismatch')
    for key in hashes:
        absent = (key == 'recoverySha256' and launch == 1) or (key.startswith('second') and launch < 3)
        if absent:
            if proof[key] is not None:
                raise ValueError('Unadmitted retry evidence present')
        elif not isinstance(proof[key], str) or re.fullmatch(r'[a-f0-9]{64}', proof[key]) is None:
            raise ValueError('Bound retry record hash missing')
    if (proof.get('reopenEntryChecked') is not (launch != 1) or
            proof.get('reopenEntryAvailable') is not (launch != 1 and not (promote and launch == 5))):
        raise ValueError('Retry production reopen entry mismatch')
    histories = proof.get('taskHistories')
    if not isinstance(histories, list) or len(histories) != count:
        raise ValueError('Retry task histories missing')
    for number, history in enumerate(histories, 1):
        if (not isinstance(history, dict) or type(history.get('runNumber')) is not int or
                history['runNumber'] != number or history.get('dispatchId') != proof['dispatchIds'][number - 1]):
            raise ValueError('Retry task history identity mismatch')
        if not isinstance(history.get('reopenSha256'), str) or re.fullmatch(r'[a-f0-9]{64}', history['reopenSha256']) is None:
            raise ValueError('Retry reopen context fingerprint missing')
        observed = {key: value for key, value in history.items() if key not in ('runNumber', 'dispatchId', 'reopenSha256')}
        if number == 1:
            read_task_history(observed, True)
        else:
            expected = [['admitted', None, None, None]]
            for operation in OPERATIONS:
                expected += [['pending', operation, None, None], ['result', operation, 0, False]]
            expected += [['finished', None, None, None]]
            if (set(observed) != {'sha256', 'projectionSha256', 'events', 'withdrawalSequence', 'pendingOperation', 'finished'} or
                    not isinstance(observed.get('sha256'), str) or re.fullmatch(r'[a-f0-9]{64}', observed['sha256']) is None or
                    observed.get('projectionSha256') != observed['sha256'] or
                    observed.get('withdrawalSequence') is not None or observed.get('pendingOperation') is not None or
                    observed.get('finished') is not True or
                    json.dumps(observed.get('events'), separators=(',', ':')) != json.dumps(expected, separators=(',', ':'))):
                raise ValueError('Retry completed task history mismatch')
    if promote:
        published = launch >= 4
        phase = 'completed' if published else 'verifying' if launch == 3 else None
        if proof.get('workingPublished') is not published or proof.get('secondExecutionPhase') != phase:
            raise ValueError('Bound publication state mismatch')
        publication = proof.get('publication')
        if not published:
            if publication is not None:
                raise ValueError('Publication outcome existed before promotion')
        elif (not isinstance(publication, dict) or set(publication) != {
                'runNumber', 'boardTaskId', 'dispatchId', 'sha256', 'projectionSha256',
                'originalWorkingSha256', 'publishedWorkingSha256'} or
                type(publication.get('runNumber')) is not int or publication['runNumber'] != 2 or
                publication.get('boardTaskId') != 'Tanalyze' or
                publication.get('dispatchId') != proof['dispatchIds'][-1] or
                not isinstance(publication.get('sha256'), str) or
                re.fullmatch(r'[a-f0-9]{64}', publication['sha256']) is None or
                publication.get('projectionSha256') != publication['sha256'] or
                publication.get('originalWorkingSha256') != proof['previousSha256'] or
                publication.get('publishedWorkingSha256') != proof['workingSha256']):
            raise ValueError('Bound publication outcome identity mismatch')
        for key in ('workingSha256', 'previousSha256'):
            if key == 'previousSha256' and not published:
                if proof[key] is not None:
                    raise ValueError('Previous publication existed before consent')
            elif not isinstance(proof[key], str) or re.fullmatch(r'[a-f0-9]{64}', proof[key]) is None:
                raise ValueError('Bound publication record missing')
    return proof


def require_retry_transition(previous, current, launch, before_hash, promote=False):
    if not isinstance(before_hash, str) or re.fullmatch(r'[a-f0-9]{64}', before_hash) is None:
        raise ValueError('Before-action retry evidence missing')
    if previous is None:
        if launch != 1 or before_hash != retry_digest(current):
            raise ValueError('Initial retry stage changed')
        return
    if before_hash != retry_digest(previous):
        raise ValueError('Read-only retry reopen changed retained records')
    if current['taskHistories'][0] != previous['taskHistories'][0]:
        raise ValueError('Retry rewrote first task history')
    immutable = {'sessionId', 'projectId', 'basisSha256', 'cancellationRequested',
                 'firstReceiptSha256', 'stopSha256'}
    if launch == 2:
        if any(current[key] == previous[key] for key in ('journalSha256', 'firstRunSha256', 'firstExecutionSha256')):
            raise ValueError('Acknowledgement transition missing')
        immutable |= {'sessionSha256', 'revision', 'dispatchCount', 'dispatchIds',
                      'candidateSha256', 'secondExecutionSha256', 'secondReceiptSha256', 'taskHistories'}
        if promote:
            immutable |= {'workingSha256', 'previousSha256', 'workingPublished', 'secondExecutionPhase'}
    elif launch == 3:
        immutable |= {'firstRunSha256', 'firstExecutionSha256', 'recoverySha256'}
        if promote:
            immutable |= {'workingSha256', 'previousSha256', 'workingPublished'}
        if current['dispatchIds'][:-1] != previous['dispatchIds']:
            raise ValueError('Retry rewrote existing session references')
        if any(current[key] == previous[key] for key in ('sessionSha256', 'journalSha256', 'candidateSha256')):
            raise ValueError('New retry admission missing')
    elif launch == 4 and promote:
        if (current['previousSha256'] != previous['workingSha256'] or
                current['workingSha256'] == previous['workingSha256'] or
                current['secondExecutionSha256'] == previous['secondExecutionSha256']):
            raise ValueError('Bound publication transition missing')
        immutable |= set(current) - {'workingSha256', 'previousSha256', 'workingPublished',
            'secondExecutionSha256', 'secondExecutionPhase', 'publication', 'receiptPreparations', 'commandEntries', 'reopenEntryChecked', 'reopenEntryAvailable'}
    elif launch == 4 or (launch == 5 and promote):
        if retry_digest(current) != before_hash:
            raise ValueError('Final read-only retry reopen changed records')
    else:
        raise ValueError('Unexpected retry transition')
    if any(previous[key] != current[key] for key in immutable):
        raise ValueError('Retry rewrote immutable prior evidence')


def read_report(root, launch, nonce, operation='resolve', stop=False, precommit=False, running=False, uncertain=False, acknowledge=False, retry=False, promote=False, promotion_crash=False, session_bound=False, admission_crash=False, session_cancel=False, session_cancel_active=False, session_cancel_unknown=False):
    report = root / f'launch-{launch}.json'
    if report.is_symlink() or not report.is_file() or report.stat().st_size > 8192:
        raise ValueError('Invalid candidate report')
    value = json.loads(report.read_text())
    if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 20 or
            type(value.get('launch')) is not int or value['launch'] != launch or value.get('nonce') != nonce or
            value.get('dispatch') != f'candidate-restart-{nonce}-1:3' or
            value.get('sessionBound') is not session_bound or value.get('admissionCrash') is not admission_crash or value.get('sessionCancel') is not session_cancel or value.get('sessionCancelActive') is not session_cancel_active or value.get('sessionCancelUnknown') is not session_cancel_unknown or
            (session_cancel_unknown and not session_cancel_active) or
            (session_cancel_active and not session_cancel) or
            (session_cancel and (not session_bound or admission_crash)) or
            (admission_crash and not session_bound) or
            (session_bound and (not stop or operation != 'test' or any((precommit, uncertain)) or ((running or acknowledge or retry or promote or promotion_crash) and not (running and acknowledge and retry and not admission_crash and not session_cancel)))) or
            operation not in OPERATIONS or value.get('operation') != operation or
            value.get('stopRequested') is not stop or value.get('precommit') is not precommit or
            (precommit and not stop) or value.get('running') is not running or
            value.get('uncertain') is not uncertain or value.get('acknowledge') is not acknowledge or value.get('retry') is not retry or value.get('promote') is not promote or value.get('promotionCrash') is not promotion_crash or
            (promotion_crash and not promote) or
            (promote and not retry) or (launch == 5 and not promote) or
            (retry and not acknowledge) or (launch == 4 and not retry) or
            (acknowledge and (not running or uncertain)) or (launch == 3 and not acknowledge) or (uncertain and not running) or
            (running and (not stop or precommit or operation != 'test')) or
            value.get('completedOperations') != ([] if admission_crash else OPERATIONS[:2] if session_cancel_unknown else OPERATIONS[:3] if session_cancel_active else ['resolve'] if session_cancel else OPERATIONS[:OPERATIONS.index(operation)])):
        raise ValueError('Candidate report identity mismatch')
    if session_bound and retry:
        if value.get('sessionProof') is not None:
            raise ValueError('Retry cannot reuse one-dispatch session proof')
        proof = read_retry_proof(value.get('sessionRetryProof'), nonce, launch, promote)
        before_hash = value.get('beforeActionSha256')
        if not isinstance(before_hash, str) or re.fullmatch(r'[a-f0-9]{64}', before_hash) is None:
            raise ValueError('Before-action retry evidence missing')
        if launch == 1:
            require_retry_transition(None, proof, launch, before_hash, promote)
    elif value.get('sessionRetryProof') is not None or value.get('beforeActionSha256') is not None:
        raise ValueError('Non-retry report contains retry evidence')
    elif session_bound:
        read_session_proof(value.get('sessionProof'), nonce, launch, admission_crash, session_cancel, session_cancel_active, session_cancel_unknown)
    elif value.get('sessionProof') is not None:
        raise ValueError('Unbound report contains session evidence')
    if session_cancel:
        wrong_test_exit = (value.get('actualTestExit') is not None if session_cancel_unknown else
            type(value.get('actualTestExit')) is not int or value['actualTestExit'] != 0)
        wrong_retained_exit = (value.get('retainedExit') is not None if session_cancel_unknown else
            type(value.get('retainedExit')) is not int or value['retainedExit'] != 0)
        if session_cancel_active and (value.get('activeBeforeExit') is not True or
                value.get('runningMarker') is not True or value.get('stopSignalled') is not False or
                wrong_test_exit):
            raise ValueError('Active cancellation boundary missing')
        if session_cancel_unknown and (value.get('privateFaultObserved') is not True or
                'actualTestExit' not in value or 'retainedExit' not in value or
                value.get('acknowledgementPresent') is not False or value.get('failedOperation') != 'test' or
                value.get('cleanup') != 'unknown'):
            raise ValueError('Unknown-result publication fault missing')
        expected_operations = OPERATIONS[:2] if session_cancel_unknown else OPERATIONS[:3] if session_cancel_active else ['resolve']
        if (value.get('runFinished') is not (not session_cancel_unknown) or value.get('candidatePhase') != 'failed' or
                value.get('pendingOperation') != ('test' if session_cancel_unknown else '') or
                value.get('executionPhase') != ('executing' if session_cancel_unknown else 'verifying') or
                wrong_retained_exit or value.get('receiptOperations') != expected_operations or
                value.get('promotionAllowed') is not False or value.get('candidateStopPresent') is not False or
                any(value.get(key) is not True for key in ('noLaterCommands', 'workingUnchanged',
                    'sourcesUnchanged', 'cancellationUnchanged', 'viewRendered')) or
                (launch == 1 and value.get('readyForCrash') is not True)):
            raise ValueError('Session cancellation or actual receipt evidence missing')
        return value
    if admission_crash:
        if (value.get('startupUnchanged') is not True or value.get('workingUnchanged') is not True or
                value.get('sourcesUnchanged') is not True or value.get('viewRendered') is not True or
                (launch == 1 and value.get('readyForCrash') is not True)):
            raise ValueError('Pre-admission crash evidence missing')
        return value
    if launch == 1:
        if (value.get('readyForCrash') is not True or value.get('stopSaveBlocked') is not precommit or
                value.get('stopSignalled') is not stop or value.get('runningMarker') is not running or value.get('publicationFault') is not uncertain):
            raise ValueError('Crash handshake missing')
    elif (value.get('interrupted') is not (launch < 3) or (value.get('retainedExit') is not None if uncertain else type(value.get('retainedExit')) is not int or value['retainedExit'] != (-1 if running else 0)) or
          value.get('intentUnchanged') is not True or
          value.get('runningCancelled') is not (running and not uncertain) or value.get('receiptOperations') != OPERATIONS[:OPERATIONS.index(operation) + (0 if uncertain else 1)] or value.get('cleanup') != 'unknown' or
          any(value.get(key) is not True for key in ('journalUnchanged', 'sourcesUnchanged', 'workingUnchanged', 'viewRendered')) or
          value.get('savedStopPresent') is not (stop and not precommit) or
          value.get('executionPhase') != ('awaitingApproval' if launch >= 3 else 'executing') or value.get('stopUnchanged') is not True):
        raise ValueError('Recovery observation mismatch')
    if session_bound and promote and launch >= 4 and value.get('previewResponded') is not (launch == 4):
        raise ValueError('Bound publication preview evidence mismatch')
    if acknowledge and launch == 2 and (value.get('acknowledgedAfterRead') is not True or value.get('afterAcknowledgementPhase') != 'awaitingApproval' or value.get('noNewDispatch') is not True):
        raise ValueError('Acknowledgement transition missing')
    if launch >= 3 and any(value.get(key) is not True for key in ('actionUnchanged', 'freshConsentRequired', 'noNewDispatch')):
        raise ValueError('Acknowledgement reopen mismatch')
    if retry and launch >= 3 and (value.get('newDispatch') != f'candidate-restart-{nonce}-2:3' or value.get('retryChecksPassed') is not True or value.get('oldEvidencePreserved') is not True):
        raise ValueError('Explicit retry evidence missing')
    if retry and launch == 3 and value.get('retriedAfterRead') is not True:
        raise ValueError('Explicit consented retry missing')
    if promotion_crash and launch == 4 and (value.get('commitGapReady') is not True or value.get('controllerSuccessDelivered') is not False or value.get('promotedAfterRead') is not False or value.get('refusedPublicationPreserved') is not True):
        raise ValueError('Committed promotion crash boundary missing')
    if promote and not promotion_crash and launch == 4 and any(value.get(key) is not True for key in ('promotedAfterRead', 'refusedPublicationPreserved')):
        raise ValueError('Explicit native promotion missing')
    if promote and launch == 5 and value.get('promotionSurvived') is not True:
        raise ValueError('Native promotion restart missing')
    return value


def observe(bundle, sdk, operation='resolve', stop=False, precommit=False, running=False, uncertain=False, acknowledge=False, retry=False, promote=False, promotion_crash=False, session_bound=False, admission_crash=False, session_cancel=False, session_cancel_active=False, session_cancel_unknown=False):
    if type(session_cancel_unknown) is not bool or (session_cancel_unknown and not session_cancel_active) or type(session_cancel_active) is not bool or (session_cancel_active and not session_cancel) or (session_cancel and (not session_bound or admission_crash)) or (admission_crash and not session_bound) or (session_bound and (not stop or operation != 'test' or any((precommit, uncertain)) or ((running or acknowledge or retry or promote or promotion_crash) and not (running and acknowledge and retry and not admission_crash and not session_cancel)))) or (promotion_crash and not promote) or (promote and not retry) or (retry and not acknowledge) or (acknowledge and (not running or uncertain)) or operation not in OPERATIONS or (uncertain and not running) or (precommit and not stop) or (running and (not stop or precommit or operation != 'test')):
        raise ValueError('Fixed crash operation required')
    if sys.platform != 'darwin':
        raise ValueError('Mac fixture only')
    executable, binary = inspect_bundle(bundle)
    sdk = Path(sdk).resolve(strict=True)
    if not (sdk / 'bin/cache/flutter_tools.snapshot').is_file():
        raise ValueError('Existing prepared SDK required')
    root = Path(tempfile.mkdtemp(prefix='asg-candidate-crash-')).resolve()
    nonce = secrets.token_hex(16)
    observations = []
    for launch in ((1, 2, 3, 4, 5) if promote else (1, 2, 3, 4) if retry else (1, 2, 3) if acknowledge else (1, 2)):
        if inspect_bundle(bundle) != (executable, binary):
            raise ValueError('Fixture binary changed')
        (root / 'challenge.json').write_text(json.dumps({'nonce': nonce, 'launch': launch, 'sdk': str(sdk), 'operation': operation, 'stop': stop, 'precommit': precommit, 'running': running, 'uncertain': uncertain, 'acknowledge': acknowledge, 'retry': retry, 'promote': promote, 'promotionCrash': promotion_crash, 'sessionBound': session_bound, 'admissionCrash': admission_crash, 'sessionCancel': session_cancel, 'sessionCancelActive': session_cancel_active, 'sessionCancelUnknown': session_cancel_unknown}))
        with (root / f'process-{launch}.log').open('wb') as log:
            process = subprocess.Popen([str(executable)],
                env={**os.environ, 'ASG_CANDIDATE_CRASH_ROOT': str(root)}, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + (180 if retry else 150)
                while not (root / f'launch-{launch}.json').exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise ValueError('Candidate app handshake failed')
                    time.sleep(0.02)
                # Writer creates exclusively, then flushes. Wait for process-independent
                # publication to finish before parsing; malformed data remains a refusal.
                while True:
                    try:
                        value = read_report(root, launch, nonce, operation, stop, precommit, running, uncertain, acknowledge, retry, promote, promotion_crash, session_bound, admission_crash, session_cancel, session_cancel_active, session_cancel_unknown)
                        break
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        if time.monotonic() > deadline:
                            raise ValueError('Candidate report incomplete')
                        time.sleep(0.02)
                if inspect_bundle(bundle) != (executable, binary):
                    raise ValueError('Fixture binary changed before crash/reopen')
                if session_bound and retry:
                    previous = observations[-1]['sessionRetryProof'] if observations else None
                    require_retry_transition(previous, value['sessionRetryProof'], launch, value['beforeActionSha256'], promote)
                if launch == 1 or (promotion_crash and launch == 4):
                    if process.poll() is not None:
                        raise ValueError('App exited before host crash')
                    process.kill()  # Only the live handle returned by this Popen.
                    if process.wait(timeout=5) != -9:
                        raise ValueError('Expected owned app crash missing')
                elif process.wait(timeout=10) != 0:
                    raise ValueError('Recovered app refused observations')
                observations.append(value)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
    if session_bound and retry:
        previous = None
        for launch, report in enumerate(observations, 1):
            current = report['sessionRetryProof']
            require_retry_transition(previous, current, launch, report['beforeActionSha256'], promote)
            previous = current
    elif session_bound:
        retained = ('sessionId', 'projectId', 'revision', 'dispatchId', 'dispatchCount',
                    'sessionSha256', 'journalSha256', 'candidateSha256', 'executionSha256', 'taskHistory', 'reopenContextSha256')
        if session_cancel:
            retained += ('receiptSha256', 'cancellationRequested')
        if session_cancel_active:
            retained += ('activeBoundarySha256',)
        if session_cancel_unknown:
            retained += ('publicationFaultSha256', 'testResultPresent')
        if any(observations[0]['sessionProof'][key] != observations[1]['sessionProof'][key]
               for key in retained):
            raise ValueError('Session startup records changed on reopen')
    if observations[0]['dispatch'] != observations[1]['dispatch']:
        raise ValueError('Recovered dispatch changed')
    if inspect_bundle(bundle) != (executable, binary):
        raise ValueError('Final binary identity changed')
    return {'operation': operation, 'bundleSha256': binary, 'controlRoot': str(root), 'observations': observations,
            'limitation': 'Fixed verification completion-gap fixture only; no automatic reconciliation or general lifecycle acceptance.'}



def read_decision_report(root, launch, nonce):
    """Strict separate protocol21: supplied evidence, actual native decision CAS."""
    file = root / f'launch-{launch}.json'
    if file.is_symlink() or file.stat().st_size > 8192:
        raise ValueError('Unsafe decision report')
    value = json.loads(file.read_text())
    keys = {'version', 'mode', 'nonce', 'launch', 'decisionPresent', 'decisionSha256',
            'evidenceSha256', 'originalRecordsUnchanged', 'unrelatedRecordsUnchanged',
            'workingSha256', 'controllerBusy', 'controllerSuccessDelivered', 'canConsent',
            'decisionCommits', 'sessionWithdrawn', 'newDecisionRefused',
            'sourceInspections', 'sdkAttempts', 'modelAttempts', 'previewAttempts'}
    if (not isinstance(value, dict) or set(value) != keys or type(launch) is not int or
            launch not in (1, 2, 3, 4, 5) or not isinstance(nonce, str) or
            re.fullmatch(r'[a-f0-9]{32}', nonce) is None or
            type(value['version']) is not int or value['version'] != 21 or
            type(value['launch']) is not int or value['launch'] != launch or
            value['mode'] != 'task-decision' or value['nonce'] != nonce):
        raise ValueError('Decision report identity mismatch')
    expected = {'decisionPresent': launch >= 3, 'originalRecordsUnchanged': launch != 5,
                'unrelatedRecordsUnchanged': True, 'controllerBusy': launch in (2, 3),
                'controllerSuccessDelivered': launch >= 4, 'canConsent': launch == 1,
                'sessionWithdrawn': launch == 5, 'newDecisionRefused': launch == 5}
    if any(type(value[k]) is not bool or value[k] != v for k, v in expected.items()):
        raise ValueError('Decision boundary facts mismatch')
    counts = {'decisionCommits': int(launch == 3), 'sourceInspections': 0,
              'sdkAttempts': 0, 'modelAttempts': 0, 'previewAttempts': 0}
    if any(type(value[k]) is not int or value[k] != v for k, v in counts.items()):
        raise ValueError('Unexpected decision write or execution')
    for key in ('workingSha256', 'decisionSha256', 'evidenceSha256'):
        fingerprint = value[key]
        if launch < 3 and key != 'workingSha256':
            if fingerprint is not None:
                raise ValueError('Decision proof present before commit')
        elif not isinstance(fingerprint, str) or re.fullmatch(r'[a-f0-9]{64}', fingerprint) is None:
            raise ValueError('Decision fingerprint missing')
    return value


def observe_decision(bundle, sdk):
    """Only launches/kills this inspected disposable fixture; never SDK/model work."""
    if sys.platform != 'darwin':
        raise ValueError('Mac fixture only')
    executable, binary = inspect_bundle(bundle)
    sdk = Path(sdk).resolve(strict=True)
    if not (sdk / 'bin/cache/flutter_tools.snapshot').is_file():
        raise ValueError('Existing prepared SDK required')
    root = Path(tempfile.mkdtemp(prefix='asg-candidate-crash-')).resolve()
    nonce = secrets.token_hex(16)
    observations = []
    for launch in (1, 2, 3, 4, 5):
        if inspect_bundle(bundle) != (executable, binary):
            raise ValueError('Fixture binary changed')
        (root / 'challenge.json').write_text(json.dumps({'mode': 'task-decision', 'nonce': nonce, 'launch': launch, 'sdk': str(sdk)}))
        with (root / f'process-{launch}.log').open('wb') as log:
            process = subprocess.Popen([str(executable)], env={**os.environ, 'ASG_CANDIDATE_CRASH_ROOT': str(root)}, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 60
                while not (root / f'launch-{launch}.json').exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise ValueError(f'Decision app handshake failed; artifacts: {root}')
                    time.sleep(0.02)
                while True:
                    try:
                        value = read_decision_report(root, launch, nonce)
                        break
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        if time.monotonic() > deadline:
                            raise ValueError('Decision report incomplete')
                        time.sleep(0.02)
                if inspect_bundle(bundle) != (executable, binary):
                    raise ValueError('Fixture binary changed before decision crash')
                if launch in (2, 3):
                    if process.poll() is not None:
                        raise ValueError('App exited before owned decision crash')
                    process.kill()
                    if process.wait(timeout=5) != -9:
                        raise ValueError('Expected owned app crash missing')
                elif process.wait(timeout=10) != 0:
                    raise ValueError('Decision reopen refused')
                observations.append(value)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
    if len({v['workingSha256'] for v in observations}) != 1 or len({v['decisionSha256'] for v in observations[2:]}) != 1 or len({v['evidenceSha256'] for v in observations[2:]}) != 1:
        raise ValueError('Decision or original working evidence changed across reopen')
    return {'version': 21, 'mode': 'task-decision', 'bundleSha256': binary, 'artifacts': str(root),
            'launches': observations, 'scope': 'Actual isolated native decision persistence and process-crash boundaries on supplied named-test observations; no SDK/model/live artifact or general task acceptance.'}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--task-decision', action='store_true')
    parser.add_argument('--repair-return-boundary', action='store_true')
    parser.add_argument('--initial-return-boundary', action='store_true')
    parser.add_argument('--return-boundary', choices=('beforeCommit', 'afterCommit'))
    parser.add_argument('--initial-unresolved', action='store_true')
    parser.add_argument('--unresolved-next', action='store_true')
    parser.add_argument('--initial-lineage', action='store_true')
    parser.add_argument('--initial-boundary', choices=('precommit', 'postcommit'))
    parser.add_argument('--initial-retry', action='store_true')
    parser.add_argument('--initial-corrupt', action='store_true')
    parser.add_argument('--repair-lineage', action='store_true')
    parser.add_argument('--lineage-boundary', choices=('precommit', 'postcommit'))
    parser.add_argument('--lineage-retry', action='store_true')
    parser.add_argument('--lineage-corrupt', action='store_true')
    parser.add_argument('--stop', action='store_true')
    parser.add_argument('--precommit', action='store_true')
    parser.add_argument('--running', action='store_true')
    parser.add_argument('--uncertain', action='store_true')
    parser.add_argument('--acknowledge', action='store_true')
    parser.add_argument('--retry', action='store_true')
    parser.add_argument('--promote', action='store_true')
    parser.add_argument('--promotion-crash', action='store_true')
    parser.add_argument('--session-bound', action='store_true')
    parser.add_argument('--admission-crash', action='store_true')
    parser.add_argument('--session-cancel', action='store_true')
    parser.add_argument('--session-cancel-active', action='store_true')
    parser.add_argument('--session-cancel-unknown', action='store_true')
    parser.add_argument('--operation', choices=OPERATIONS + ['all'], default='resolve')
    args = parser.parse_args()
    try:
        if args.initial_return_boundary or args.repair_return_boundary:
            if args.initial_return_boundary and args.repair_return_boundary:
                raise ValueError('Exactly one terminal-return mode required')
            if (args.initial_unresolved or args.unresolved_next or args.initial_lineage or
                    args.initial_boundary is not None or args.initial_retry or args.initial_corrupt or
                    args.repair_lineage or args.lineage_boundary is not None or args.lineage_retry or
                    args.lineage_corrupt or args.task_decision or args.operation != 'resolve' or
                    any((args.stop, args.precommit, args.running, args.uncertain, args.acknowledge,
                        args.retry, args.promote, args.promotion_crash, args.session_bound,
                        args.admission_crash, args.session_cancel, args.session_cancel_active,
                        args.session_cancel_unknown))):
                raise ValueError('Terminal-return mode cannot combine other scenarios')
            runner = (native_repair_return_boundary.run_repair_return_boundary if args.repair_return_boundary
                      else native_initial_return_boundary.run_initial_return_boundary)
            print(json.dumps(runner(args.bundle, args.sdk, args.return_boundary or 'beforeCommit')))
        elif args.return_boundary is not None:
            raise ValueError('Return boundary requires its explicit primary mode')
        elif args.initial_unresolved:
            if (args.initial_lineage or args.initial_boundary is not None or args.initial_retry or
                    args.initial_corrupt or args.repair_lineage or args.lineage_boundary is not None or
                    args.lineage_retry or args.lineage_corrupt or args.task_decision or
                    args.operation != 'resolve' or any((args.stop, args.precommit, args.running,
                        args.uncertain, args.acknowledge, args.retry, args.promote, args.promotion_crash,
                        args.session_bound, args.admission_crash, args.session_cancel,
                        args.session_cancel_active, args.session_cancel_unknown))):
                raise ValueError('Unresolved initial mode cannot combine other scenarios')
            print(json.dumps(native_initial_unresolved.run_initial_unresolved(
                args.bundle, args.sdk, args.unresolved_next)))
        elif args.unresolved_next:
            raise ValueError('Unresolved next requires its explicit primary mode')
        elif args.initial_lineage:
            if (args.repair_lineage or args.lineage_boundary is not None or args.lineage_retry or
                    args.lineage_corrupt or args.task_decision or args.operation != 'resolve' or
                    any((args.stop, args.precommit, args.running, args.uncertain, args.acknowledge,
                         args.retry, args.promote, args.promotion_crash, args.session_bound,
                         args.admission_crash, args.session_cancel, args.session_cancel_active,
                         args.session_cancel_unknown))):
                raise ValueError('Initial-lineage mode cannot combine other scenarios')
            native_initial_lineage.validate_mode(args.initial_boundary or 'postcommit',
                args.initial_retry, args.initial_corrupt)
            print(json.dumps(native_initial_lineage.observe(args.bundle, args.sdk,
                args.initial_boundary or 'postcommit', args.initial_retry, args.initial_corrupt)))
        elif args.initial_boundary is not None or args.initial_retry or args.initial_corrupt:
            raise ValueError('Initial-lineage options require their explicit mode')
        elif args.repair_lineage:
            if args.task_decision or args.operation != 'resolve' or any((args.stop, args.precommit, args.running, args.uncertain, args.acknowledge, args.retry, args.promote, args.promotion_crash, args.session_bound, args.admission_crash, args.session_cancel, args.session_cancel_active, args.session_cancel_unknown)):
                raise ValueError('Repair-lineage mode cannot combine legacy scenarios')
            native_repair_lineage.validate_mode(args.lineage_boundary or 'postcommit',
                args.lineage_retry, args.lineage_corrupt)
            print(json.dumps(native_repair_lineage.observe(args.bundle, args.sdk,
                args.lineage_boundary or 'postcommit', args.lineage_retry, args.lineage_corrupt)))
        elif args.lineage_boundary is not None or args.lineage_retry or args.lineage_corrupt:
            raise ValueError('Repair-lineage options require their explicit mode')
        elif args.task_decision:
            if args.operation != 'resolve' or any((args.stop, args.precommit, args.running, args.uncertain, args.acknowledge, args.retry, args.promote, args.promotion_crash, args.session_bound, args.admission_crash, args.session_cancel, args.session_cancel_active, args.session_cancel_unknown)):
                raise ValueError('Decision-only mode cannot combine execution scenarios')
            print(json.dumps(observe_decision(args.bundle, args.sdk)))
        elif args.operation == 'all':
            observations = [observe(args.bundle, args.sdk, operation, args.stop, args.precommit, args.running, args.uncertain, args.acknowledge, args.retry, args.promote, args.promotion_crash, args.session_bound, args.admission_crash, args.session_cancel, args.session_cancel_active, args.session_cancel_unknown) for operation in OPERATIONS]
            if len({item['bundleSha256'] for item in observations}) != 1:
                raise ValueError('Matrix binary changed')
            print(json.dumps({'matrix': observations}))
        else:
            print(json.dumps(observe(args.bundle, args.sdk, args.operation, args.stop, args.precommit, args.running, args.uncertain, args.acknowledge, args.retry, args.promote, args.promotion_crash, args.session_bound, args.admission_crash, args.session_cancel, args.session_cancel_active, args.session_cancel_unknown)))
    except (ValueError, OSError, subprocess.TimeoutExpired):
        parser.exit(2, 'Candidate crash fixture refused or failed; artifacts retained.\n')


if __name__ == '__main__':
    main()
