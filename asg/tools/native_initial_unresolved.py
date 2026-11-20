# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Bounded protocol24 observations, not proof of remote outcome or permission.

Only fixed disposable fixture children are launched; SDK/model tools never run.
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
MAX_CHALLENGE_BYTES = 4096
MODEL = 'supplied-native-initial-unresolved-model'
REPORT_KEYS = frozenset({
    'version', 'mode', 'nonce', 'launch', 'explicitNext', 'stage', 'projectId', 'sessionId',
    'boardTaskId', 'requirementId', 'requestedModel', 'requestCount',
    'unresolvedRequestNumber', 'latestRequestNumber', 'unresolvedRequestStatus',
    'latestRequestStatus', 'unresolvedRequestSha256', 'latestRequestSha256',
    'unresolvedResponseModel', 'latestResponseModel', 'unresolvedReturnedSourceSha256',
    'latestReturnedSourceSha256', 'originalSessionSha256', 'sessionRevision',
    'sessionDispatchCount', 'requestReference', 'recordsBefore', 'recordsAfter',
    'unrelatedBeforeSha256', 'unrelatedAfterSha256', 'declaredSourceSha256', 'counters'})
RECORD_SLOTS = frozenset({
    'working', 'requestJournal', 'session', 'candidateJournal', 'candidate', 'execution',
    'history', 'context', 'initialCompanion', 'repairCompanion'})
COUNTER_KEYS = frozenset({
    'setupCalls', 'proposalCalls', 'reservationCommits', 'reservationReturns',
    'suppliedProviderCalls', 'proposalReturns', 'terminalCommits', 'liveTransportAttempts',
    'sdkAttempts', 'candidateEffects', 'unrelatedWrites', 'previewAttempts', 'sourceCopies',
    'hostCreations'})
REFERENCE_KEYS = frozenset({'version', 'projectId', 'sessionId', 'number', 'requestSha256'})


def _hash(value):
    return isinstance(value, str) and re.fullmatch(r'[a-f0-9]{64}', value) is not None


def _int(value, expected):
    return type(value) is int and value == expected


def _identity(launch, nonce, explicit_next):
    if (type(launch) is not int or launch not in (1, 2, 3, 4) or
            type(explicit_next) is not bool or explicit_next != (launch >= 3) or
            not isinstance(nonce, str) or re.fullmatch(r'[a-f0-9]{32}', nonce) is None):
        raise ValueError('Invalid unresolved initial observation identity')


def validate_report(value, launch, nonce, explicit_next=False):
    """Validate fixed observations; matching hashes do not authenticate provenance."""
    _identity(launch, nonce, explicit_next)
    if not isinstance(value, dict) or set(value) != REPORT_KEYS:
        raise ValueError('Unresolved initial report shape mismatch')
    project, session = f'restart-{nonce}', f'session-{nonce}'
    latest = 2 if explicit_next else 1
    expected = {'mode': 'initial-unresolved', 'nonce': nonce,
        'stage': {1: 'reserved-paused', 2: 'read-only', 3: 'fresh-return-paused',
                  4: 'fresh-read-only'}[launch], 'projectId': project, 'sessionId': session,
        'boardTaskId': 'Tanalyze', 'requirementId': 'R1', 'requestedModel': MODEL,
        'unresolvedRequestStatus': 'reserved',
        'latestRequestStatus': 'returnedValidated' if explicit_next else 'reserved'}
    if (any(value[key] != item for key, item in expected.items()) or
            any(not _int(value[key], item) for key, item in {'version': 24, 'launch': launch,
                'requestCount': latest, 'unresolvedRequestNumber': 1, 'latestRequestNumber': latest,
                'sessionRevision': 0, 'sessionDispatchCount': 0}.items()) or
            value['explicitNext'] is not explicit_next):
        raise ValueError('Unresolved initial identity, stage or request count mismatch')
    for key in ('unresolvedRequestSha256', 'latestRequestSha256', 'originalSessionSha256',
                'unrelatedBeforeSha256', 'unrelatedAfterSha256', 'declaredSourceSha256'):
        if not _hash(value[key]):
            raise ValueError('Missing strict unresolved observation hash')
    if value['unresolvedResponseModel'] is not None or value['unresolvedReturnedSourceSha256'] is not None:
        raise ValueError('Unknown request acquired a fabricated response')
    reference = value['requestReference']
    if explicit_next:
        if (value['latestResponseModel'] != MODEL or not _hash(value['latestReturnedSourceSha256']) or
                value['latestRequestSha256'] == value['unresolvedRequestSha256'] or
                not isinstance(reference, dict) or set(reference) != REFERENCE_KEYS or
                not _int(reference['version'], 1) or not _int(reference['number'], 2) or
                reference['projectId'] != project or reference['sessionId'] != session or
                reference['requestSha256'] != value['latestRequestSha256']):
            raise ValueError('Fresh returned request identity/reference mismatch')
    elif (value['latestResponseModel'] is not None or value['latestReturnedSourceSha256'] is not None or
            reference is not None or value['latestRequestSha256'] != value['unresolvedRequestSha256']):
        raise ValueError('Reserved request was relabelled returned or referenced')
    before, after = value['recordsBefore'], value['recordsAfter']
    for records in (before, after):
        if not isinstance(records, dict) or set(records) != RECORD_SLOTS:
            raise ValueError('Exact unresolved raw record slots required')
        if any(not _hash(records[key]) for key in ('working', 'session')):
            raise ValueError('Retained working/session baseline missing')
        if records['requestJournal'] is not None and not _hash(records['requestJournal']):
            raise ValueError('Invalid request journal raw hash')
        if any(records[key] is not None for key in RECORD_SLOTS - {'working', 'session', 'requestJournal'}):
            raise ValueError('Unexpected candidate or execution lineage record')
        if records['session'] != value['originalSessionSha256']:
            raise ValueError('Original raw session changed')
    if (before['requestJournal'] is None) != (launch == 1) or not _hash(after['requestJournal']):
        raise ValueError('Reservation cohort missing or already occupied')
    if any(before[key] != after[key] for key in RECORD_SLOTS - {'requestJournal'}):
        raise ValueError('Reservation changed a record outside the request journal')
    if (before['requestJournal'] != after['requestJournal']) != (launch in (1, 3)):
        raise ValueError('Unexpected request journal write or missing commit')
    if value['unrelatedBeforeSha256'] != value['unrelatedAfterSha256']:
        raise ValueError('Unrelated native records changed')
    counts = {key: 0 for key in COUNTER_KEYS}
    if launch == 1:
        counts.update(setupCalls=1, proposalCalls=1, reservationCommits=1)
    elif launch == 3:
        counts.update(proposalCalls=1, reservationCommits=1, reservationReturns=1,
                      suppliedProviderCalls=1, proposalReturns=1, terminalCommits=1)
    if (not isinstance(value['counters'], dict) or set(value['counters']) != COUNTER_KEYS or
            any(not _int(value['counters'][key], count) for key, count in counts.items())):
        raise ValueError('Unexpected unresolved proposal or execution effects')
    return value


def require_transition(previous, current):
    if not isinstance(current, dict):
        raise ValueError('Unresolved observation missing')
    launch, nonce = current.get('launch'), current.get('nonce')
    validate_report(current, launch, nonce, current.get('explicitNext'))
    if previous is None:
        if launch != 1:
            raise ValueError('Initial reservation observation missing')
        return
    if not isinstance(previous, dict) or launch == 1:
        raise ValueError('Prior unresolved observation missing')
    validate_report(previous, launch - 1, nonce, launch - 1 >= 3)
    if previous['recordsAfter'] != current['recordsBefore']:
        raise ValueError('Records changed between owned launches')
    stable = ('projectId', 'sessionId', 'boardTaskId', 'requirementId', 'requestedModel',
        'unresolvedRequestNumber', 'unresolvedRequestStatus', 'unresolvedRequestSha256',
        'unresolvedResponseModel', 'unresolvedReturnedSourceSha256', 'originalSessionSha256',
        'declaredSourceSha256')
    if any(previous[key] != current[key] for key in stable):
        raise ValueError('Immutable unresolved intent or baseline changed')
    if previous['unrelatedAfterSha256'] != current['unrelatedBeforeSha256']:
        raise ValueError('Unrelated records changed between launches')
    if launch in (2, 4):
        cold = ('requestCount', 'latestRequestNumber', 'latestRequestStatus', 'latestRequestSha256',
                'latestResponseModel', 'latestReturnedSourceSha256', 'requestReference')
        if any(previous[key] != current[key] for key in cold):
            raise ValueError('Cold reopen changed retained request metadata')


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('Duplicate unresolved JSON member')
        result[key] = value
    return result


def _constant(_):
    raise ValueError('Nonfinite unresolved JSON value')


def _file_identity(file):
    info = file.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_REPORT_BYTES:
        raise ValueError('Bounded regular nonsymlink report required')
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def read_report(root, launch, nonce, explicit_next=False):
    _identity(launch, nonce, explicit_next)
    root = Path(root)
    if root.resolve(strict=True) != root or not root.is_dir():
        raise ValueError('Canonical unresolved report root required')
    file = root / f'launch-{launch}.json'
    identity = _file_identity(file)
    descriptor = os.open(file, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0))
    try:
        info = os.fstat(descriptor)
        if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns) != identity:
            raise ValueError('Report replaced before reading')
        with os.fdopen(descriptor, 'rb', closefd=False) as stream:
            raw = stream.read(MAX_REPORT_BYTES + 1)
        if len(raw) > MAX_REPORT_BYTES:
            raise ValueError('Unresolved report exceeded bound while reading')
        try:
            value = json.loads(raw.decode('utf-8'), object_pairs_hook=_pairs, parse_constant=_constant)
        except json.JSONDecodeError as error:
            raise json.JSONDecodeError('Incomplete unresolved report', '', 0) from error
    finally:
        os.close(descriptor)
    if _file_identity(file) != identity:
        raise ValueError('Report replaced while reading')
    return validate_report(value, launch, nonce, explicit_next)



def _write_challenge(root, launch, raw, previous_identity):
    """Replace only our pinned challenge; never follow an artifact link."""
    target = root / 'challenge.json'
    if previous_identity is None:
        try:
            target.lstat()
        except FileNotFoundError:
            pass
        else:
            raise ValueError('Fresh challenge path required')
    elif _file_identity(target) != previous_identity:
        raise ValueError('Challenge changed between owned launches')
    temporary = root / f'challenge-{launch}.tmp'
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                         getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(descriptor, 'wb') as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    identity = _file_identity(temporary)
    os.replace(temporary, target)
    published = _file_identity(target)
    # Rename may update ctime; pin the final full identity after verifying inode,
    # size and mtime belong to the exclusively created file.
    if published[:4] != identity[:4]:
        raise ValueError('Challenge replaced while publishing')
    return published


def run_initial_unresolved(bundle, sdk, explicit_next=False):
    """Observe only fixed owned disposable children; no SDK/model command execution."""
    if type(explicit_next) is not bool:
        raise ValueError('Explicit next selection must be boolean')
    if sys.platform != 'darwin':
        raise ValueError('Mac unresolved initial fixture only')
    executable, binary = inspect_bundle(bundle)
    sdk = Path(sdk)
    if not sdk.is_absolute() or any(c in str(sdk) for c in ('\0', '\n', '\r')):
        raise ValueError('Existing canonical SDK required')
    if sdk.resolve(strict=True) != sdk or not (sdk / 'bin/cache/flutter_tools.snapshot').is_file():
        raise ValueError('Existing canonical prepared SDK required')
    created_root = Path(tempfile.mkdtemp(prefix='asg-candidate-crash-'))
    if created_root.is_symlink():
        raise ValueError('Disposable root must not be a symlink')
    # The macOS system temp prefix may use /var, an OS alias of /private/var.
    root = created_root.resolve(strict=True)
    if not root.is_dir() or root.stat().st_mode & 0o077:
        raise ValueError('Private canonical disposable root required')
    root_identity = root.stat().st_dev, root.stat().st_ino
    nonce = secrets.token_hex(16)
    observations = []
    challenge_identity = None
    for launch in ((1, 2, 3, 4) if explicit_next else (1, 2)):
        if (root.resolve(strict=True) != root or (root.stat().st_dev, root.stat().st_ino) != root_identity or
                inspect_bundle(bundle) != (executable, binary)):
            raise ValueError('Fixture root or binary changed')
        next_stage = launch >= 3
        challenge = json.dumps({'mode': 'initial-unresolved', 'nonce': nonce, 'launch': launch,
                                'sdk': str(sdk), 'explicitNext': next_stage}).encode('utf-8')
        if len(challenge) > MAX_CHALLENGE_BYTES:
            raise ValueError('Unresolved challenge exceeded bound')
        challenge_identity = _write_challenge(root, launch, challenge, challenge_identity)
        log_descriptor = os.open(root / f'process-{launch}.log',
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, 'O_NOFOLLOW', 0), 0o600)
        with os.fdopen(log_descriptor, 'wb') as log:
            process = subprocess.Popen([str(executable)],
                env={**os.environ, 'ASG_CANDIDATE_CRASH_ROOT': str(root)}, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 60
                file = root / f'launch-{launch}.json'
                while True:
                    try:
                        identity = _file_identity(file)
                        value = read_report(root, launch, nonce, next_stage)
                        if _file_identity(file) != identity:
                            raise ValueError('Report replaced after strict reading')
                        break
                    except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError):
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise ValueError('Owned unresolved report missing or incomplete')
                        time.sleep(0.02)
                require_transition(observations[-1] if observations else None, value)
                if (inspect_bundle(bundle) != (executable, binary) or
                        root.resolve(strict=True) != root or
                        (root.stat().st_dev, root.stat().st_ino) != root_identity or
                        _file_identity(file) != identity):
                    raise ValueError('Fixture binary/root/report changed before owned boundary')
                if launch in (1, 3):
                    if process.poll() is not None:
                        raise ValueError('App exited before owned reservation crash')
                    process.kill()
                    if process.wait(timeout=5) != -9:
                        raise ValueError('Expected owned reservation crash missing')
                elif process.wait(timeout=10) != 0:
                    raise ValueError('Read-only unresolved reopen refused')
                if _file_identity(file) != identity:
                    raise ValueError('Report replaced at owned boundary')
                observations.append(value)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
    if inspect_bundle(bundle) != (executable, binary):
        raise ValueError('Final unresolved fixture binary changed')
    return {'version': 24, 'mode': 'initial-unresolved', 'explicitNext': explicit_next,
        'bundleSha256': binary, 'artifacts': str(root), 'launches': observations,
        'scope': 'Owned native reservation/reopen observations and optional fresh supplied request; no remote outcome, live inference, source restoration or execution permission.'}
