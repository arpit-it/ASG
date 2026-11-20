# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Bounded protocol26 observations, not proof of remote outcome or permission.

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
MODEL = 'supplied-native-repair-return-boundary-model'
REPORT_KEYS = frozenset({
    'version', 'mode', 'nonce', 'launch', 'boundary', 'stage', 'projectId', 'sessionId',
    'boardTaskId', 'requirementId', 'requestedModel', 'attemptCount', 'attemptNumber',
    'attemptStatus', 'attemptSha256', 'originSha256', 'failureSha256',
    'originalSessionSha256', 'sessionRevision', 'sessionDispatchCount', 'storedResponseModel',
    'storedProposalSha256', 'validatedResponseModel', 'validatedProposalSha256',
    'declaredSourceSha256', 'deliveredReference', 'retainedReference', 'recordsBefore',
    'recordsAfter', 'unrelatedBeforeSha256', 'unrelatedAfterSha256', 'counters'})
RECORD_SLOTS = frozenset({
    'working', 'repairOrigin', 'repairJournal', 'failureJournal', 'failedCandidate',
    'session', 'execution', 'history', 'context', 'initialCompanion', 'repairCompanion'})
COUNTER_KEYS = frozenset({
    'setupCalls', 'failureSetupCalls', 'proposalCalls', 'reservationCommits',
    'reservationReturns', 'suppliedProviderCalls', 'proposalReturns', 'terminalAttempts',
    'terminalCommits', 'terminalReturns', 'liveTransportAttempts', 'sdkAttempts',
    'candidateEffects', 'unrelatedWrites', 'previewAttempts', 'sourceCopies', 'hostCreations'})
REFERENCE_KEYS = frozenset({'version', 'projectId', 'attemptNumber', 'attemptSha256', 'originSha256'})


def _hash(value):
    return isinstance(value, str) and re.fullmatch(r'[a-f0-9]{64}', value) is not None


def _int(value, expected):
    return type(value) is int and value == expected


def _identity(launch, nonce, boundary):
    if (type(launch) is not int or launch not in (1, 2) or
            boundary not in ('beforeCommit', 'afterCommit') or
            not isinstance(nonce, str) or re.fullmatch(r'[a-f0-9]{32}', nonce) is None):
        raise ValueError('Invalid repair-return observation identity')


def validate_report(value, launch, nonce, boundary):
    """Validate stored versus supplied versus delivered observations separately."""
    _identity(launch, nonce, boundary)
    if not isinstance(value, dict) or set(value) != REPORT_KEYS:
        raise ValueError('Repair-return report shape mismatch')
    project, session = f'restart-{nonce}', f'session-{nonce}'
    committed = boundary == 'afterCommit'
    expected = {'mode': 'repair-return-boundary', 'nonce': nonce, 'boundary': boundary,
        'stage': 'held-terminal' if launch == 1 else 'cold-retained',
        'projectId': project, 'sessionId': session, 'boardTaskId': 'Tanalyze',
        'requirementId': 'R1', 'requestedModel': MODEL,
        'attemptStatus': 'proposed' if committed else 'reserved'}
    if (any(value[key] != item for key, item in expected.items()) or
            any(not _int(value[key], item) for key, item in {'version': 26, 'launch': launch,
                'attemptCount': 1, 'attemptNumber': 1, 'sessionRevision': 0,
                'sessionDispatchCount': 0}.items())):
        raise ValueError('Repair-return identity, stage or attempt mismatch')
    for key in ('attemptSha256', 'originSha256', 'failureSha256', 'originalSessionSha256', 'unrelatedBeforeSha256',
                'unrelatedAfterSha256', 'declaredSourceSha256'):
        if not _hash(value[key]):
            raise ValueError('Missing strict repair-return observation hash')
    if value['deliveredReference'] is not None:
        raise ValueError('Held proposal was incorrectly labelled delivered')
    if launch == 1:
        if value['validatedResponseModel'] != MODEL or not _hash(value['validatedProposalSha256']):
            raise ValueError('Held validated supplied metadata missing')
    elif value['validatedResponseModel'] is not None or value['validatedProposalSha256'] is not None:
        raise ValueError('Cold read claimed a supplied response or proposal restoration')
    if committed:
        if value['storedResponseModel'] != MODEL or not _hash(value['storedProposalSha256']):
            raise ValueError('Committed stored response metadata missing')
        if launch == 1 and value['storedProposalSha256'] != value['validatedProposalSha256']:
            raise ValueError('Stored and validated proposal metadata differ')
    elif value['storedResponseModel'] is not None or value['storedProposalSha256'] is not None:
        raise ValueError('Precommit pending metadata was presented as stored')
    reference = value['retainedReference']
    if launch == 2 and committed:
        if (not isinstance(reference, dict) or set(reference) != REFERENCE_KEYS or
                not _int(reference['version'], 1) or not _int(reference['attemptNumber'], 1) or
                reference['projectId'] != project or
                reference['attemptSha256'] != value['attemptSha256'] or
                reference['originSha256'] != value['originSha256']):
            raise ValueError('Cold retained record reference mismatch')
    elif reference is not None:
        raise ValueError('Held or reserved attempt acquired a retained reference')
    before, after = value['recordsBefore'], value['recordsAfter']
    immutable = {'working', 'session', 'failureJournal', 'failedCandidate'}
    for records in (before, after):
        if not isinstance(records, dict) or set(records) != RECORD_SLOTS:
            raise ValueError('Exact repair-return raw record slots required')
        if any(not _hash(records[key]) for key in immutable):
            raise ValueError('Retained failed/working/session baseline missing')
        if any(records[key] is not None for key in RECORD_SLOTS - immutable - {'repairJournal', 'repairOrigin'}):
            raise ValueError('Unexpected execution or lineage record')
        if records['session'] != value['originalSessionSha256']:
            raise ValueError('Original raw session changed')
    if any(before[key] != after[key] for key in immutable):
        raise ValueError('Repair reservation changed a retained baseline record')
    for key in ('repairJournal', 'repairOrigin'):
        if ((before[key] is None) != (launch == 1) or not _hash(after[key]) or
                (launch == 2 and not _hash(before[key]))):
            raise ValueError('Repair reservation cohort missing or already occupied')
    if value['originSha256'] != after['repairOrigin']:
        raise ValueError('Origin identity does not match exact retained origin bytes')
    if launch == 2 and before != after:
        raise ValueError('Cold repair read wrote native records')
    if value['unrelatedBeforeSha256'] != value['unrelatedAfterSha256']:
        raise ValueError('Unrelated native records changed')
    counts = {key: 0 for key in COUNTER_KEYS}
    if launch == 1:
        counts.update(setupCalls=1, failureSetupCalls=1, proposalCalls=1, reservationCommits=1, reservationReturns=1,
                      suppliedProviderCalls=1, terminalAttempts=1, terminalCommits=int(committed))
    if (not isinstance(value['counters'], dict) or set(value['counters']) != COUNTER_KEYS or
            any(not _int(value['counters'][key], count) for key, count in counts.items())):
        raise ValueError('Unexpected repair-return proposal or execution effects')
    return value


def require_transition(previous, current):
    if not isinstance(current, dict):
        raise ValueError('Repair-return observation missing')
    launch, nonce, boundary = current.get('launch'), current.get('nonce'), current.get('boundary')
    validate_report(current, launch, nonce, boundary)
    if previous is None:
        if launch != 1:
            raise ValueError('Initial repair hold observation missing')
        return
    if not isinstance(previous, dict) or launch != 2:
        raise ValueError('Prior terminal hold observation missing')
    validate_report(previous, 1, nonce, boundary)
    if previous['recordsAfter'] != current['recordsBefore']:
        raise ValueError('Records changed between held and cold launches')
    stable = ('projectId', 'sessionId', 'boardTaskId', 'requirementId', 'requestedModel',
        'attemptCount', 'attemptNumber', 'attemptStatus', 'attemptSha256', 'originSha256',
        'failureSha256', 'storedResponseModel',
        'storedProposalSha256', 'originalSessionSha256', 'declaredSourceSha256')
    if any(previous[key] != current[key] for key in stable):
        raise ValueError('Retained repair attempt or baseline changed')
    if previous['unrelatedAfterSha256'] != current['unrelatedBeforeSha256']:
        raise ValueError('Unrelated records changed between launches')


def _pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            raise ValueError('Duplicate repair-return JSON member')
        result[key] = value
    return result


def _constant(_):
    raise ValueError('Nonfinite repair-return JSON value')


def _file_identity(file):
    info = file.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_REPORT_BYTES:
        raise ValueError('Bounded regular nonsymlink report required')
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def read_report(root, launch, nonce, boundary):
    _identity(launch, nonce, boundary)
    root = Path(root)
    if root.resolve(strict=True) != root or not root.is_dir():
        raise ValueError('Canonical repair-return report root required')
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
            raise json.JSONDecodeError('Incomplete repair-return report', '', 0) from error
        except RecursionError as error:
            raise ValueError('Repair-return JSON nesting exceeded parser limit') from error
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


def run_repair_return_boundary(bundle, sdk, boundary='beforeCommit'):
    """Observe only fixed owned disposable children; no SDK/model command execution."""
    if boundary not in ('beforeCommit', 'afterCommit'):
        raise ValueError('Fixed repair-return boundary required')
    if sys.platform != 'darwin':
        raise ValueError('Mac repair-return fixture only')
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
        challenge = json.dumps({'mode': 'repair-return-boundary', 'nonce': nonce, 'launch': launch,
                                'sdk': str(sdk), 'boundary': boundary}).encode('utf-8')
        if len(challenge) > MAX_CHALLENGE_BYTES:
            raise ValueError('Repair-return challenge exceeded bound')
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
                            raise ValueError('Owned repair-return report missing or incomplete')
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
                    raise ValueError('Read-only repair-return reopen refused')
                if (_file_identity(file) != identity or
                        _file_identity(root / 'challenge.json') != challenge_identity):
                    raise ValueError('Control/report replaced at owned boundary')
                observations.append(value)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
    if inspect_bundle(bundle) != (executable, binary):
        raise ValueError('Final repair-return fixture binary changed')
    return {'version': 26, 'mode': 'repair-return-boundary', 'boundary': boundary,
        'bundleSha256': binary, 'artifacts': str(root), 'launches': observations,
        'scope': 'Owned native terminal hold/reopen observations of one supplied validated repair attempt; no remote outcome, live inference, source restoration or execution permission.'}
