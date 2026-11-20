# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Bounded protocol25 observations, not proof of remote outcome or permission.

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
MODEL = 'supplied-native-initial-return-boundary-model'
REPORT_KEYS = frozenset({
    'version', 'mode', 'nonce', 'launch', 'boundary', 'stage', 'projectId', 'sessionId',
    'boardTaskId', 'requirementId', 'requestedModel', 'requestCount', 'requestNumber',
    'requestStatus', 'requestSha256', 'storedResponseModel', 'storedReturnedSourceSha256',
    'validatedResponseModel', 'validatedReturnedSourceSha256', 'originalSessionSha256',
    'sessionRevision', 'sessionDispatchCount', 'deliveredReference', 'retainedReference',
    'recordsBefore', 'recordsAfter', 'unrelatedBeforeSha256', 'unrelatedAfterSha256',
    'declaredSourceSha256', 'counters'})
RECORD_SLOTS = frozenset({
    'working', 'requestJournal', 'session', 'candidateJournal', 'candidate', 'execution',
    'history', 'context', 'initialCompanion', 'repairCompanion'})
COUNTER_KEYS = frozenset({
    'setupCalls', 'proposalCalls', 'reservationCommits', 'reservationReturns',
    'suppliedProviderCalls', 'proposalReturns', 'terminalAttempts', 'terminalCommits',
    'terminalReturns', 'liveTransportAttempts', 'sdkAttempts', 'candidateEffects',
    'unrelatedWrites', 'previewAttempts', 'sourceCopies', 'hostCreations'})
REFERENCE_KEYS = frozenset({'version', 'projectId', 'sessionId', 'number', 'requestSha256'})


def _hash(value):
    return isinstance(value, str) and re.fullmatch(r'[a-f0-9]{64}', value) is not None


def _int(value, expected):
    return type(value) is int and value == expected


def _identity(launch, nonce, boundary):
    if (type(launch) is not int or launch not in (1, 2) or
            boundary not in ('beforeCommit', 'afterCommit') or
            not isinstance(nonce, str) or re.fullmatch(r'[a-f0-9]{32}', nonce) is None):
        raise ValueError('Invalid terminal-return observation identity')


def validate_report(value, launch, nonce, boundary):
    """Validate stored versus supplied versus delivered observations separately."""
    _identity(launch, nonce, boundary)
    if not isinstance(value, dict) or set(value) != REPORT_KEYS:
        raise ValueError('Terminal-return report shape mismatch')
    project, session = f'restart-{nonce}', f'session-{nonce}'
    committed = boundary == 'afterCommit'
    expected = {'mode': 'initial-return-boundary', 'nonce': nonce, 'boundary': boundary,
        'stage': 'held-terminal' if launch == 1 else 'cold-retained',
        'projectId': project, 'sessionId': session, 'boardTaskId': 'Tanalyze',
        'requirementId': 'R1', 'requestedModel': MODEL,
        'requestStatus': 'returnedValidated' if committed else 'reserved'}
    if (any(value[key] != item for key, item in expected.items()) or
            any(not _int(value[key], item) for key, item in {'version': 25, 'launch': launch,
                'requestCount': 1, 'requestNumber': 1, 'sessionRevision': 0,
                'sessionDispatchCount': 0}.items())):
        raise ValueError('Terminal-return identity, stage or request mismatch')
    for key in ('requestSha256', 'originalSessionSha256', 'unrelatedBeforeSha256',
                'unrelatedAfterSha256', 'declaredSourceSha256'):
        if not _hash(value[key]):
            raise ValueError('Missing strict terminal-return observation hash')
    if value['deliveredReference'] is not None:
        raise ValueError('Held proposal was incorrectly labelled delivered')
    if launch == 1:
        if value['validatedResponseModel'] != MODEL or not _hash(value['validatedReturnedSourceSha256']):
            raise ValueError('Held validated supplied metadata missing')
    elif value['validatedResponseModel'] is not None or value['validatedReturnedSourceSha256'] is not None:
        raise ValueError('Cold read claimed a supplied response or proposal restoration')
    if committed:
        if value['storedResponseModel'] != MODEL or not _hash(value['storedReturnedSourceSha256']):
            raise ValueError('Committed stored response metadata missing')
        if launch == 1 and value['storedReturnedSourceSha256'] != value['validatedReturnedSourceSha256']:
            raise ValueError('Stored and validated source-map metadata differ')
    elif value['storedResponseModel'] is not None or value['storedReturnedSourceSha256'] is not None:
        raise ValueError('Precommit pending metadata was presented as stored')
    reference = value['retainedReference']
    if launch == 2 and committed:
        if (not isinstance(reference, dict) or set(reference) != REFERENCE_KEYS or
                not _int(reference['version'], 1) or not _int(reference['number'], 1) or
                reference['projectId'] != project or reference['sessionId'] != session or
                reference['requestSha256'] != value['requestSha256']):
            raise ValueError('Cold retained record reference mismatch')
    elif reference is not None:
        raise ValueError('Held or reserved request acquired a retained reference')
    before, after = value['recordsBefore'], value['recordsAfter']
    for records in (before, after):
        if not isinstance(records, dict) or set(records) != RECORD_SLOTS:
            raise ValueError('Exact terminal-return raw record slots required')
        if any(not _hash(records[key]) for key in ('working', 'session')):
            raise ValueError('Retained working/session/request baseline missing')
        if any(records[key] is not None for key in RECORD_SLOTS - {'working', 'session', 'requestJournal'}):
            raise ValueError('Unexpected candidate or execution lineage record')
        if records['session'] != value['originalSessionSha256']:
            raise ValueError('Original raw session changed')
    if any(before[key] != after[key] for key in RECORD_SLOTS - {'requestJournal'}):
        raise ValueError('Terminal commit changed a record outside the request journal')
    if ((before['requestJournal'] is None) != (launch == 1) or
            not _hash(after['requestJournal']) or
            (launch == 2 and not _hash(before['requestJournal']))):
        raise ValueError('Reservation journal cohort missing or already occupied')
    if launch == 2 and before['requestJournal'] != after['requestJournal']:
        raise ValueError('Cold terminal read wrote the request journal')
    if value['unrelatedBeforeSha256'] != value['unrelatedAfterSha256']:
        raise ValueError('Unrelated native records changed')
    counts = {key: 0 for key in COUNTER_KEYS}
    if launch == 1:
        counts.update(setupCalls=1, proposalCalls=1, reservationCommits=1, reservationReturns=1,
                      suppliedProviderCalls=1, terminalAttempts=1, terminalCommits=int(committed))
    if (not isinstance(value['counters'], dict) or set(value['counters']) != COUNTER_KEYS or
            any(not _int(value['counters'][key], count) for key, count in counts.items())):
        raise ValueError('Unexpected terminal-return proposal or execution effects')
    return value


def require_transition(previous, current):
    if not isinstance(current, dict):
        raise ValueError('Terminal-return observation missing')
    launch, nonce, boundary = current.get('launch'), current.get('nonce'), current.get('boundary')
    validate_report(current, launch, nonce, boundary)
    if previous is None:
        if launch != 1:
            raise ValueError('Initial terminal hold observation missing')
        return
    if not isinstance(previous, dict) or launch != 2:
        raise ValueError('Prior terminal hold observation missing')
    validate_report(previous, 1, nonce, boundary)
    if previous['recordsAfter'] != current['recordsBefore']:
        raise ValueError('Records changed between held and cold launches')
    stable = ('projectId', 'sessionId', 'boardTaskId', 'requirementId', 'requestedModel',
        'requestCount', 'requestNumber', 'requestStatus', 'requestSha256', 'storedResponseModel',
        'storedReturnedSourceSha256', 'originalSessionSha256', 'declaredSourceSha256')
    if any(previous[key] != current[key] for key in stable):
        raise ValueError('Retained terminal request or baseline changed')
    if previous['unrelatedAfterSha256'] != current['unrelatedBeforeSha256']:
        raise ValueError('Unrelated records changed between launches')


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('Duplicate terminal-return JSON member')
        result[key] = value
    return result


def _constant(_):
    raise ValueError('Nonfinite terminal-return JSON value')


def _file_identity(file):
    info = file.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_REPORT_BYTES:
        raise ValueError('Bounded regular nonsymlink report required')
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def read_report(root, launch, nonce, boundary):
    _identity(launch, nonce, boundary)
    root = Path(root)
    if root.resolve(strict=True) != root or not root.is_dir():
        raise ValueError('Canonical terminal-return report root required')
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
            raise json.JSONDecodeError('Incomplete terminal-return report', '', 0) from error
    finally:
        os.close(descriptor)
    if _file_identity(file) != identity:
        raise ValueError('Report replaced while reading')
    return validate_report(value, launch, nonce, boundary)



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


def run_initial_return_boundary(bundle, sdk, boundary='beforeCommit'):
    """Observe only fixed owned disposable children; no SDK/model command execution."""
    if boundary not in ('beforeCommit', 'afterCommit'):
        raise ValueError('Fixed terminal-return boundary required')
    if sys.platform != 'darwin':
        raise ValueError('Mac terminal-return fixture only')
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
    for launch in (1, 2):
        if (root.resolve(strict=True) != root or (root.stat().st_dev, root.stat().st_ino) != root_identity or
                inspect_bundle(bundle) != (executable, binary)):
            raise ValueError('Fixture root or binary changed')
        try:
            (root / f'launch-{launch}.json').lstat()
        except FileNotFoundError:
            pass
        else:
            raise ValueError('Fresh owned report path required')
        challenge = json.dumps({'mode': 'initial-return-boundary', 'nonce': nonce, 'launch': launch,
                                'sdk': str(sdk), 'boundary': boundary}).encode('utf-8')
        if len(challenge) > MAX_CHALLENGE_BYTES:
            raise ValueError('Terminal-return challenge exceeded bound')
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
                        value = read_report(root, launch, nonce, boundary)
                        if _file_identity(file) != identity:
                            raise ValueError('Report replaced after strict reading')
                        break
                    except (FileNotFoundError, json.JSONDecodeError, UnicodeDecodeError):
                        if process.poll() is not None or time.monotonic() > deadline:
                            raise ValueError('Owned terminal-return report missing or incomplete')
                        time.sleep(0.02)
                require_transition(observations[-1] if observations else None, value)
                if (inspect_bundle(bundle) != (executable, binary) or
                        root.resolve(strict=True) != root or
                        (root.stat().st_dev, root.stat().st_ino) != root_identity or
                        _file_identity(file) != identity or
                        _file_identity(root / 'challenge.json') != challenge_identity):
                    raise ValueError('Fixture binary/root/report changed before owned boundary')
                if launch == 1:
                    if process.poll() is not None:
                        raise ValueError('App exited before owned terminal crash')
                    process.kill()
                    if process.wait(timeout=5) != -9:
                        raise ValueError('Expected owned terminal crash missing')
                elif process.wait(timeout=10) != 0:
                    raise ValueError('Read-only terminal-return reopen refused')
                if (_file_identity(file) != identity or
                        _file_identity(root / 'challenge.json') != challenge_identity):
                    raise ValueError('Control/report replaced at owned boundary')
                observations.append(value)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
    if inspect_bundle(bundle) != (executable, binary):
        raise ValueError('Final terminal-return fixture binary changed')
    return {'version': 25, 'mode': 'initial-return-boundary', 'boundary': boundary,
        'bundleSha256': binary, 'artifacts': str(root), 'launches': observations,
        'scope': 'Owned native terminal hold/reopen observations of one supplied validated request; no remote outcome, live inference, source restoration or execution permission.'}
