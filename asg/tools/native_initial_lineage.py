# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Strict protocol23 observations for an explicitly supplied disposable Mac fixture.

These reports are bounded app observations, not authenticated lineage or permission.
The driver only signals its own live subprocess handles; it never builds or installs.
"""
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time

from native_restart_probe import inspect_bundle

MAX_REPORT_BYTES = 8192
MODEL = 'supplied-native-initial-lineage-model'
RECORD_SLOTS = frozenset({
    'working', 'requestJournal', 'journal', 'candidate', 'session', 'execution1', 'history1',
    'context1', 'companion1', 'execution2', 'history2', 'context2', 'companion2',
    'repairCompanion1', 'repairCompanion2'})
COUNTER_KEYS = frozenset({
    'setupProviderCalls', 'sourceSetupCalls', 'requestSetupCalls', 'hostCreations',
    'recoverySourceInspections', 'startupCalls', 'startupRecordUpdates', 'startupReturns',
    'hostEntries', 'receiptPreparations', 'liveModelTransportAttempts', 'sourceCopies',
    'sdkAttempts', 'previewAttempts', 'unrelatedRecordWrites', 'corruptionControls'})
REPORT_KEYS = frozenset({
    'version', 'mode', 'nonce', 'launch', 'boundary', 'corruptOptional', 'stage', 'projectId',
    'sessionId', 'boardTaskId', 'requirementId', 'requestedModel', 'observedModel',
    'selectedRequestNumber', 'latestRequestNumber', 'requestCount', 'requestReference',
    'selectedRequestSha256', 'latestRequestSha256', 'selectedReturnedSourceSha256',
    'latestReturnedSourceSha256', 'targetRunNumber', 'targetDispatchId',
    'committedTargetRunNumber', 'committedTargetDispatchId', 'proofState',
    'originalRequestSessionSha256', 'capturedAdmissionSessionSha256',
    'durableAdmissionSessionSha256', 'contextSha256', 'companionSha256', 'sessionRevision',
    'sessionDispatchCount', 'recordsBefore', 'recordsAfter', 'unrelatedBeforeSha256',
    'unrelatedAfterSha256', 'workingSourceSha256', 'preparedSourceSha256', 'counters'})
REFERENCE_KEYS = frozenset({'version', 'projectId', 'sessionId', 'number', 'requestSha256'})
BASE_SLOTS = frozenset({'working', 'requestJournal', 'session'})
IMMUTABLE_SLOTS = frozenset({'working', 'requestJournal'})


def _hash(value):
    return isinstance(value, str) and re.fullmatch(r'[a-f0-9]{64}', value) is not None


def _int(value, expected):
    return type(value) is int and value == expected


def validate_mode(boundary, retry=False, corrupt_optional=False):
    if (boundary not in ('precommit', 'postcommit') or type(retry) is not bool or
            type(corrupt_optional) is not bool or (retry and corrupt_optional) or
            ((retry or corrupt_optional) and boundary != 'postcommit')):
        raise ValueError('Invalid fixed initial-lineage scenario')


def _identity(launch, nonce, boundary, corrupt_optional):
    validate_mode(boundary, False, corrupt_optional)
    if (type(launch) is not int or launch not in (1, 2, 3, 4) or
            (boundary == 'precommit' and launch > 2) or
            (corrupt_optional and launch != 2) or not isinstance(nonce, str) or
            re.fullmatch(r'[a-f0-9]{32}', nonce) is None):
        raise ValueError('Invalid initial-lineage observation identity')


def _run_slots(number):
    return {f'{prefix}{number}' for prefix in ('execution', 'history', 'context', 'companion')}


def _records(value):
    if not isinstance(value, dict) or set(value) != RECORD_SLOTS:
        raise ValueError('Fixed initial-lineage record members required')
    if any(item is not None and not _hash(item) for item in value.values()):
        raise ValueError('Invalid initial-lineage raw record hash')
    if any(not _hash(value[key]) for key in BASE_SLOTS):
        raise ValueError('Retained initial baseline record missing')


def _presence(records, run1, run2):
    for number, present in ((1, run1), (2, run2)):
        for key in _run_slots(number):
            if (present and not _hash(records[key])) or (not present and records[key] is not None):
                raise ValueError('Initial-lineage startup slot presence mismatch')


def validate_report(value, launch, nonce, boundary, corrupt_optional=False):
    """Validate stage-specific observations; a matching report grants no authority."""
    _identity(launch, nonce, boundary, corrupt_optional)
    if not isinstance(value, dict) or set(value) != REPORT_KEYS:
        raise ValueError('Initial-lineage report shape mismatch')
    target = 1 if launch <= 2 else 2
    admitted = boundary == 'postcommit'
    project = f'restart-{nonce}'
    dispatch = f'candidate-{project}-{target}:3'
    stage = {1: 'paused', 2: 'read-only', 3: 'retry-paused', 4: 'retry-read-only'}[launch]
    expected = {'mode': 'initial-lineage', 'nonce': nonce, 'boundary': boundary,
        'stage': stage, 'projectId': project, 'sessionId': f'session-{nonce}',
        'boardTaskId': 'Tanalyze', 'requirementId': 'R1',
        'requestedModel': MODEL, 'observedModel': MODEL, 'targetDispatchId': dispatch,
        'proofState': 'unavailable' if corrupt_optional else 'joined' if admitted else 'absent'}
    if (any(value[key] != item for key, item in expected.items()) or
            not _int(value['version'], 23) or not _int(value['launch'], launch) or
            value['corruptOptional'] is not corrupt_optional or
            not _int(value['selectedRequestNumber'], 1) or not _int(value['latestRequestNumber'], 2) or
            not _int(value['requestCount'], 2) or
            not _int(value['targetRunNumber'], target) or
            not _int(value['sessionRevision'], target if admitted else 0) or
            not _int(value['sessionDispatchCount'], target if admitted else 0)):
        raise ValueError('Initial-lineage identity or stage mismatch')
    if admitted:
        if not _int(value['committedTargetRunNumber'], target) or value['committedTargetDispatchId'] != dispatch:
            raise ValueError('Committed target identity missing')
    elif value['committedTargetRunNumber'] is not None or value['committedTargetDispatchId'] is not None:
        raise ValueError('Captured intent was presented as committed identity')
    reference = value['requestReference']
    if (not isinstance(reference, dict) or set(reference) != REFERENCE_KEYS or
            not _int(reference['version'], 1) or not _int(reference['number'], 1) or
            reference['projectId'] != project or reference['sessionId'] != f'session-{nonce}' or
            not _hash(reference['requestSha256']) or
            any(not _hash(value[key]) for key in ('selectedRequestSha256', 'latestRequestSha256',
                'selectedReturnedSourceSha256', 'latestReturnedSourceSha256')) or
            reference['requestSha256'] != value['selectedRequestSha256'] or
            value['selectedRequestSha256'] == value['latestRequestSha256'] or
            value['selectedReturnedSourceSha256'] != value['latestReturnedSourceSha256']):
        raise ValueError('Explicit selected request reference or returned map mismatch')
    before, after = value['recordsBefore'], value['recordsAfter']
    _records(before)
    _records(after)
    _presence(before, admitted and launch >= 2, admitted and launch == 4)
    _presence(after, admitted, admitted and launch >= 3)
    for records, present in ((before, admitted and launch >= 2), (after, admitted)):
        if any(records[key] is not None for key in ('repairCompanion1', 'repairCompanion2')):
            raise ValueError('Opposite repair companion slot occupied')
        for key in ('journal', 'candidate'):
            if (present and not _hash(records[key])) or (not present and records[key] is not None):
                raise ValueError('Initial journal/candidate presence mismatch')
    if any(before[key] != after[key] for key in IMMUTABLE_SLOTS):
        raise ValueError('Original request journal or working records changed')
    if launch in (1, 3) and admitted:
        cohort = {'journal', 'candidate', 'session'} | _run_slots(target)
        required_changes = {'journal', 'session'} | _run_slots(target)
        # A retry can rewrite the same canonical candidate snapshot. The cohort
        # describes transaction members, not seven necessarily different hashes.
        if (any(before[key] == after[key] for key in required_changes) or
                any(before[key] != after[key] for key in RECORD_SLOTS - cohort)):
            raise ValueError('Atomic seven-record startup cohort mismatch')
    elif corrupt_optional:
        if any((before[key] == after[key]) != (key != 'companion1') for key in RECORD_SLOTS):
            raise ValueError('Optional corruption changed unrelated records')
    elif before != after:
        raise ValueError('Read-only or precommit stage wrote records')
    hashes = ('originalRequestSessionSha256', 'capturedAdmissionSessionSha256',
        'unrelatedBeforeSha256', 'unrelatedAfterSha256', 'workingSourceSha256', 'preparedSourceSha256')
    if any(not _hash(value[key]) for key in hashes):
        raise ValueError('Required initial-lineage observation hash missing')
    if value['unrelatedBeforeSha256'] != value['unrelatedAfterSha256']:
        raise ValueError('Unrelated native records changed')
    captured = value['capturedAdmissionSessionSha256']
    if target == 1 and captured != value['originalRequestSessionSha256']:
        raise ValueError('Original raw request session changed before first admission')
    if launch in (1, 3) and captured != before['session']:
        raise ValueError('Captured session is not the actual entry raw session')
    if target == 2 and captured == value['originalRequestSessionSha256']:
        raise ValueError('Retry reused the original pre-admission session')
    durable = value['durableAdmissionSessionSha256']
    if value['proofState'] == 'joined':
        if durable != captured:
            raise ValueError('Joined proof lost actual pre-admission raw identity')
    elif durable is not None:
        raise ValueError('Absent or corrupt proof acquired a joined admission')
    if (value['contextSha256'] != after[f'context{target}'] or
            value['companionSha256'] != after[f'companion{target}']):
        raise ValueError('Durable context/companion does not match fixed stored slots')
    counts = {key: 0 for key in COUNTER_KEYS}
    if launch == 1:
        counts.update(setupProviderCalls=2, sourceSetupCalls=1, requestSetupCalls=2, hostCreations=1)
    if launch == 3:
        counts.update(hostCreations=2, recoverySourceInspections=2)
    counts.update(startupCalls=int(launch in (1, 3)),
        startupRecordUpdates=7 if admitted and launch in (1, 3) else 0,
        corruptionControls=int(corrupt_optional))
    if (not isinstance(value['counters'], dict) or set(value['counters']) != COUNTER_KEYS or
            any(not _int(value['counters'][key], count) for key, count in counts.items())):
        raise ValueError('Unexpected initial-lineage setup, write or execution counters')
    return value


def require_transition(previous, current):
    """Pin across-launch observations; never infer lineage from equal content."""
    if not isinstance(current, dict):
        raise ValueError('Initial-lineage transition missing')
    launch, nonce, boundary = current.get('launch'), current.get('nonce'), current.get('boundary')
    validate_report(current, launch, nonce, boundary, current.get('corruptOptional'))
    if previous is None:
        if launch != 1:
            raise ValueError('First initial-lineage observation missing')
        return
    if not isinstance(previous, dict):
        raise ValueError('Prior initial-lineage observation missing')
    validate_report(previous, launch - 1, nonce, boundary, previous.get('corruptOptional'))
    if launch == 1 or previous['corruptOptional']:
        raise ValueError('Invalid initial-lineage observation sequence')
    if previous['recordsAfter'] != current['recordsBefore']:
        raise ValueError('Native records changed between owned launches')
    stable = ('projectId', 'sessionId', 'boardTaskId', 'requirementId', 'requestedModel',
        'observedModel', 'selectedRequestNumber', 'latestRequestNumber', 'requestCount',
        'requestReference', 'selectedRequestSha256', 'latestRequestSha256',
        'selectedReturnedSourceSha256', 'latestReturnedSourceSha256',
        'originalRequestSessionSha256', 'workingSourceSha256', 'preparedSourceSha256')
    if any(previous[key] != current[key] for key in stable):
        raise ValueError('Retry/reopen changed original request or source observations')
    if previous['unrelatedAfterSha256'] != current['unrelatedBeforeSha256']:
        raise ValueError('Unrelated records changed between launches')
    if launch == 3:
        if (previous['proofState'] != 'joined' or
                current['capturedAdmissionSessionSha256'] != previous['recordsAfter']['session'] or
                any(current['recordsAfter'][key] != previous['recordsAfter'][key] for key in _run_slots(1))):
            raise ValueError('Retry lost its prior proof or actual current pre-session')
    elif current['capturedAdmissionSessionSha256'] != previous['capturedAdmissionSessionSha256']:
        raise ValueError('Cold reopen changed captured pre-admission identity')


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('Duplicate initial-lineage JSON member')
        result[key] = value
    return result


def _constant(_):
    raise ValueError('Nonfinite initial-lineage JSON value')


def read_report(root, launch, nonce, boundary, corrupt_optional=False):
    _identity(launch, nonce, boundary, corrupt_optional)
    root = Path(root)
    if root.resolve(strict=True) != root or not root.is_dir():
        raise ValueError('Canonical initial-lineage artifact root required')
    file = root / f'launch-{launch}.json'
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0)
    descriptor = os.open(file, flags)
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_size > MAX_REPORT_BYTES:
            raise ValueError('Invalid bounded initial-lineage report file')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            raw = stream.read(MAX_REPORT_BYTES + 1)
        if len(raw) > MAX_REPORT_BYTES:
            raise ValueError('Initial-lineage report exceeded bound while reading')
        try:
            value = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs, parse_constant=_constant)
        except json.JSONDecodeError as error:
            raise json.JSONDecodeError('Initial-lineage report is incomplete or invalid', '', 0) from error
    finally:
        os.close(descriptor)
    return validate_report(value, launch, nonce, boundary, corrupt_optional)


def observe(bundle, sdk, boundary='postcommit', retry=False, corrupt_optional=False):
    """Run fixed owned app scenarios only; no builds, SDK/model commands or saved PIDs."""
    validate_mode(boundary, retry, corrupt_optional)
    if sys.platform != 'darwin':
        raise ValueError('Mac native initial-lineage fixture only')
    executable, binary = inspect_bundle(bundle)
    sdk = Path(sdk)
    if not sdk.is_absolute() or any(c in str(sdk) for c in ('\0', '\n', '\r')):
        raise ValueError('Existing absolute SDK path required')
    sdk = sdk.resolve(strict=True)
    if not (sdk / 'bin/cache/flutter_tools.snapshot').is_file():
        raise ValueError('Existing prepared SDK required')
    root = Path(tempfile.mkdtemp(prefix='asg-candidate-crash-')).resolve()
    nonce = secrets.token_hex(16)
    observations = []
    for launch in ((1, 2, 3, 4) if retry else (1, 2)):
        if inspect_bundle(bundle) != (executable, binary):
            raise ValueError('Fixture binary changed')
        corrupted = corrupt_optional and launch == 2
        challenge = {'mode': 'initial-lineage', 'nonce': nonce, 'launch': launch,
            'boundary': boundary, 'corruptOptional': corrupted, 'sdk': str(sdk)}
        (root / 'challenge.json').write_text(json.dumps(challenge))
        with (root / f'process-{launch}.log').open('wb') as log:
            process = subprocess.Popen([str(executable)],
                env={**os.environ, 'ASG_CANDIDATE_CRASH_ROOT': str(root)}, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 60
                while not (root / f'launch-{launch}.json').exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise ValueError('Native initial-lineage app handshake failed')
                    time.sleep(0.02)
                while True:
                    try:
                        value = read_report(root, launch, nonce, boundary, corrupted)
                        break
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        if time.monotonic() > deadline:
                            raise ValueError('Native initial-lineage report incomplete')
                        time.sleep(0.02)
                require_transition(observations[-1] if observations else None, value)
                if inspect_bundle(bundle) != (executable, binary):
                    raise ValueError('Fixture binary changed before owned crash')
                if launch in (1, 3):
                    if process.poll() is not None:
                        raise ValueError('App exited before owned initial-lineage crash')
                    process.kill()
                    if process.wait(timeout=5) != -9:
                        raise ValueError('Expected owned app crash missing')
                elif process.wait(timeout=10) != 0:
                    raise ValueError('Read-only initial-lineage reopen refused')
                observations.append(value)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
    if inspect_bundle(bundle) != (executable, binary):
        raise ValueError('Final initial-lineage binary changed')
    return {'version': 23, 'mode': 'initial-lineage', 'boundary': boundary,
        'retry': retry, 'corruptOptional': corrupt_optional, 'bundleSha256': binary,
        'artifacts': str(root), 'launches': observations,
        'scope': 'Owned native metadata startup/reopen and explicit recovery retry on supplied initial request/source observations; no live model, SDK result, authenticated weights or general task completion.'}
