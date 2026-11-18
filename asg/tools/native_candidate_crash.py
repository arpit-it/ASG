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

OPERATIONS = ['resolve', 'analyze', 'test', 'build']


def read_session_proof(value, nonce, launch, admission_crash=False, session_cancel=False):
    """Validate fixed session evidence; this never authorizes or launches work."""
    keys = {'sessionId', 'projectId', 'revision', 'dispatchId', 'dispatchCount',
            'sessionSha256', 'journalSha256', 'candidateSha256', 'executionSha256',
            'receiptPreparations', 'commandEntries'}
    if session_cancel:
        keys |= {'cancellationRequested', 'receiptSha256'}
    if (not isinstance(value, dict) or set(value) != keys or
            not isinstance(nonce, str) or re.fullmatch(r'[a-f0-9]{32}', nonce) is None or
            type(launch) is not int or launch not in (1, 2) or
            type(admission_crash) is not bool or type(session_cancel) is not bool or
            (session_cancel and admission_crash) or
            value.get('sessionId') != f'session-{nonce}' or
            value.get('projectId') != f'restart-{nonce}'):
        raise ValueError('Session evidence identity mismatch')
    admitted = not admission_crash
    expected_counts = {'revision': 2 if session_cancel else int(admitted), 'dispatchCount': int(admitted),
                       'receiptPreparations': int(admitted and launch == 1),
                       'commandEntries': (1 if session_cancel else 3) if admitted and launch == 1 else 0}
    if (any(type(value.get(key)) is not int or value[key] != count
            for key, count in expected_counts.items()) or
            value.get('dispatchId') != (f'candidate-restart-{nonce}-1:3' if admitted else None)):
        raise ValueError('Session admission or no-replay evidence mismatch')
    if session_cancel and value.get('cancellationRequested') is not True:
        raise ValueError('Session cancellation intent missing')
    for key in ('sessionSha256', 'journalSha256', 'candidateSha256', 'executionSha256') + (('receiptSha256',) if session_cancel else ()):
        fingerprint = value.get(key)
        if key != 'sessionSha256' and not admitted:
            if fingerprint is not None:
                raise ValueError('Uncommitted startup record was retained')
        elif not isinstance(fingerprint, str) or re.fullmatch(r'[a-f0-9]{64}', fingerprint) is None:
            raise ValueError('Session record fingerprint missing')
    return value


def retry_digest(proof):
    stable = {key: value for key, value in proof.items()
              if key not in ('receiptPreparations', 'commandEntries')}
    return hashlib.sha256(json.dumps(stable, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def read_retry_proof(proof, nonce, launch):
    if type(launch) is not int or launch not in (1, 2, 3, 4):
        raise ValueError('Invalid retry proof stage')
    hashes = {'basisSha256', 'sessionSha256', 'journalSha256', 'candidateSha256',
              'firstRunSha256', 'firstExecutionSha256', 'firstReceiptSha256', 'stopSha256',
              'recoverySha256', 'secondExecutionSha256', 'secondReceiptSha256'}
    keys = hashes | {'sessionId', 'projectId', 'revision', 'dispatchCount', 'dispatchIds',
                     'cancellationRequested', 'receiptPreparations', 'commandEntries'}
    count = 2 if launch >= 3 else 1
    if (not isinstance(proof, dict) or set(proof) != keys or type(launch) is not int or
            launch not in (1, 2, 3, 4) or not isinstance(nonce, str) or
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
    return proof


def require_retry_transition(previous, current, launch, before_hash):
    if not isinstance(before_hash, str) or re.fullmatch(r'[a-f0-9]{64}', before_hash) is None:
        raise ValueError('Before-action retry evidence missing')
    if previous is None:
        if launch != 1 or before_hash != retry_digest(current):
            raise ValueError('Initial retry stage changed')
        return
    if before_hash != retry_digest(previous):
        raise ValueError('Read-only retry reopen changed retained records')
    immutable = {'sessionId', 'projectId', 'basisSha256', 'cancellationRequested',
                 'firstReceiptSha256', 'stopSha256'}
    if launch == 2:
        if any(current[key] == previous[key] for key in ('journalSha256', 'firstRunSha256', 'firstExecutionSha256')):
            raise ValueError('Acknowledgement transition missing')
        immutable |= {'sessionSha256', 'revision', 'dispatchCount', 'dispatchIds',
                      'candidateSha256', 'secondExecutionSha256', 'secondReceiptSha256'}
    elif launch == 3:
        immutable |= {'firstRunSha256', 'firstExecutionSha256', 'recoverySha256'}
        if current['dispatchIds'][:-1] != previous['dispatchIds']:
            raise ValueError('Retry rewrote existing session references')
        if any(current[key] == previous[key] for key in ('sessionSha256', 'journalSha256', 'candidateSha256')):
            raise ValueError('New retry admission missing')
    elif launch == 4:
        if retry_digest(current) != before_hash:
            raise ValueError('Final read-only retry reopen changed records')
    else:
        raise ValueError('Unexpected retry transition')
    if any(previous[key] != current[key] for key in immutable):
        raise ValueError('Retry rewrote immutable prior evidence')


def read_report(root, launch, nonce, operation='resolve', stop=False, precommit=False, running=False, uncertain=False, acknowledge=False, retry=False, promote=False, promotion_crash=False, session_bound=False, admission_crash=False, session_cancel=False):
    report = root / f'launch-{launch}.json'
    if report.is_symlink() or not report.is_file() or report.stat().st_size > 4096:
        raise ValueError('Invalid candidate report')
    value = json.loads(report.read_text())
    if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 13 or
            type(value.get('launch')) is not int or value['launch'] != launch or value.get('nonce') != nonce or
            value.get('dispatch') != f'candidate-restart-{nonce}-1:3' or
            value.get('sessionBound') is not session_bound or value.get('admissionCrash') is not admission_crash or value.get('sessionCancel') is not session_cancel or
            (session_cancel and (not session_bound or admission_crash)) or
            (admission_crash and not session_bound) or
            (session_bound and (not stop or operation != 'test' or any((precommit, uncertain, promote, promotion_crash)) or ((running or acknowledge or retry) and not (running and acknowledge and retry and not admission_crash and not session_cancel)))) or
            operation not in OPERATIONS or value.get('operation') != operation or
            value.get('stopRequested') is not stop or value.get('precommit') is not precommit or
            (precommit and not stop) or value.get('running') is not running or
            value.get('uncertain') is not uncertain or value.get('acknowledge') is not acknowledge or value.get('retry') is not retry or value.get('promote') is not promote or value.get('promotionCrash') is not promotion_crash or
            (promotion_crash and not promote) or
            (promote and not retry) or (launch == 5 and not promote) or
            (retry and not acknowledge) or (launch == 4 and not retry) or
            (acknowledge and (not running or uncertain)) or (launch == 3 and not acknowledge) or (uncertain and not running) or
            (running and (not stop or precommit or operation != 'test')) or
            value.get('completedOperations') != ([] if admission_crash else ['resolve'] if session_cancel else OPERATIONS[:OPERATIONS.index(operation)])):
        raise ValueError('Candidate report identity mismatch')
    if session_bound and retry:
        if value.get('sessionProof') is not None:
            raise ValueError('Retry cannot reuse one-dispatch session proof')
        proof = read_retry_proof(value.get('sessionRetryProof'), nonce, launch)
        before_hash = value.get('beforeActionSha256')
        if not isinstance(before_hash, str) or re.fullmatch(r'[a-f0-9]{64}', before_hash) is None:
            raise ValueError('Before-action retry evidence missing')
        if launch == 1:
            require_retry_transition(None, proof, launch, before_hash)
    elif value.get('sessionRetryProof') is not None or value.get('beforeActionSha256') is not None:
        raise ValueError('Non-retry report contains retry evidence')
    elif session_bound:
        read_session_proof(value.get('sessionProof'), nonce, launch, admission_crash, session_cancel)
    elif value.get('sessionProof') is not None:
        raise ValueError('Unbound report contains session evidence')
    if session_cancel:
        if (value.get('runFinished') is not True or value.get('candidatePhase') != 'failed' or
                value.get('pendingOperation') != '' or value.get('executionPhase') != 'verifying' or
                type(value.get('retainedExit')) is not int or value['retainedExit'] != 0 or
                value.get('receiptOperations') != ['resolve'] or value.get('promotionAllowed') is not False or
                value.get('candidateStopPresent') is not False or
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


def observe(bundle, sdk, operation='resolve', stop=False, precommit=False, running=False, uncertain=False, acknowledge=False, retry=False, promote=False, promotion_crash=False, session_bound=False, admission_crash=False, session_cancel=False):
    if (session_cancel and (not session_bound or admission_crash)) or (admission_crash and not session_bound) or (session_bound and (not stop or operation != 'test' or any((precommit, uncertain, promote, promotion_crash)) or ((running or acknowledge or retry) and not (running and acknowledge and retry and not admission_crash and not session_cancel)))) or (promotion_crash and not promote) or (promote and not retry) or (retry and not acknowledge) or (acknowledge and (not running or uncertain)) or operation not in OPERATIONS or (uncertain and not running) or (precommit and not stop) or (running and (not stop or precommit or operation != 'test')):
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
        (root / 'challenge.json').write_text(json.dumps({'nonce': nonce, 'launch': launch, 'sdk': str(sdk), 'operation': operation, 'stop': stop, 'precommit': precommit, 'running': running, 'uncertain': uncertain, 'acknowledge': acknowledge, 'retry': retry, 'promote': promote, 'promotionCrash': promotion_crash, 'sessionBound': session_bound, 'admissionCrash': admission_crash, 'sessionCancel': session_cancel}))
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
                        value = read_report(root, launch, nonce, operation, stop, precommit, running, uncertain, acknowledge, retry, promote, promotion_crash, session_bound, admission_crash, session_cancel)
                        break
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        if time.monotonic() > deadline:
                            raise ValueError('Candidate report incomplete')
                        time.sleep(0.02)
                if inspect_bundle(bundle) != (executable, binary):
                    raise ValueError('Fixture binary changed before crash/reopen')
                if session_bound and retry:
                    previous = observations[-1]['sessionRetryProof'] if observations else None
                    require_retry_transition(previous, value['sessionRetryProof'], launch, value['beforeActionSha256'])
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
            require_retry_transition(previous, current, launch, report['beforeActionSha256'])
            previous = current
    elif session_bound:
        retained = ('sessionId', 'projectId', 'revision', 'dispatchId', 'dispatchCount',
                    'sessionSha256', 'journalSha256', 'candidateSha256', 'executionSha256')
        if session_cancel:
            retained += ('receiptSha256', 'cancellationRequested')
        if any(observations[0]['sessionProof'][key] != observations[1]['sessionProof'][key]
               for key in retained):
            raise ValueError('Session startup records changed on reopen')
    if observations[0]['dispatch'] != observations[1]['dispatch']:
        raise ValueError('Recovered dispatch changed')
    if inspect_bundle(bundle) != (executable, binary):
        raise ValueError('Final binary identity changed')
    return {'operation': operation, 'bundleSha256': binary, 'controlRoot': str(root), 'observations': observations,
            'limitation': 'Fixed verification completion-gap fixture only; no automatic reconciliation or general lifecycle acceptance.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--sdk', required=True)
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
    parser.add_argument('--operation', choices=OPERATIONS + ['all'], default='resolve')
    args = parser.parse_args()
    try:
        if args.operation == 'all':
            observations = [observe(args.bundle, args.sdk, operation, args.stop, args.precommit, args.running, args.uncertain, args.acknowledge, args.retry, args.promote, args.promotion_crash, args.session_bound, args.admission_crash, args.session_cancel) for operation in OPERATIONS]
            if len({item['bundleSha256'] for item in observations}) != 1:
                raise ValueError('Matrix binary changed')
            print(json.dumps({'matrix': observations}))
        else:
            print(json.dumps(observe(args.bundle, args.sdk, args.operation, args.stop, args.precommit, args.running, args.uncertain, args.acknowledge, args.retry, args.promote, args.promotion_crash, args.session_bound, args.admission_crash, args.session_cancel)))
    except (ValueError, OSError, subprocess.TimeoutExpired):
        parser.exit(2, 'Candidate crash fixture refused or failed; artifacts retained.\n')


if __name__ == '__main__':
    main()
