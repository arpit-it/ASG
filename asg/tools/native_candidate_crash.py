# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Crash/reopen only a verified disposable native candidate fixture; never builds or installs."""
import argparse
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time

from native_restart_probe import inspect_bundle

OPERATIONS = ['resolve', 'analyze', 'test', 'build']


def read_report(root, launch, nonce, operation='resolve', stop=False, precommit=False, running=False, uncertain=False):
    report = root / f'launch-{launch}.json'
    if report.is_symlink() or not report.is_file() or report.stat().st_size > 4096:
        raise ValueError('Invalid candidate report')
    value = json.loads(report.read_text())
    if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 6 or
            type(value.get('launch')) is not int or value['launch'] != launch or value.get('nonce') != nonce or
            value.get('dispatch') != f'candidate-restart-{nonce}-1:3' or
            operation not in OPERATIONS or value.get('operation') != operation or
            value.get('stopRequested') is not stop or value.get('precommit') is not precommit or
            (precommit and not stop) or value.get('running') is not running or
            value.get('uncertain') is not uncertain or (uncertain and not running) or
            (running and (not stop or precommit or operation != 'test')) or
            value.get('completedOperations') != OPERATIONS[:OPERATIONS.index(operation)]):
        raise ValueError('Candidate report identity mismatch')
    if launch == 1:
        if (value.get('readyForCrash') is not True or value.get('stopSaveBlocked') is not precommit or
                value.get('stopSignalled') is not stop or value.get('runningMarker') is not running or value.get('publicationFault') is not uncertain):
            raise ValueError('Crash handshake missing')
    elif (value.get('interrupted') is not True or (value.get('retainedExit') is not None if uncertain else type(value.get('retainedExit')) is not int or value['retainedExit'] != (-1 if running else 0)) or
          value.get('intentUnchanged') is not True or
          value.get('runningCancelled') is not (running and not uncertain) or value.get('receiptOperations') != OPERATIONS[:OPERATIONS.index(operation) + (0 if uncertain else 1)] or value.get('cleanup') != 'unknown' or
          any(value.get(key) is not True for key in ('journalUnchanged', 'sourcesUnchanged', 'workingUnchanged', 'viewRendered')) or
          value.get('savedStopPresent') is not (stop and not precommit) or
          value.get('executionPhase') != 'executing' or value.get('stopUnchanged') is not True):
        raise ValueError('Recovery observation mismatch')
    return value


def observe(bundle, sdk, operation='resolve', stop=False, precommit=False, running=False, uncertain=False):
    if operation not in OPERATIONS or (uncertain and not running) or (precommit and not stop) or (running and (not stop or precommit or operation != 'test')):
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
    for launch in (1, 2):
        if inspect_bundle(bundle) != (executable, binary):
            raise ValueError('Fixture binary changed')
        (root / 'challenge.json').write_text(json.dumps({'nonce': nonce, 'launch': launch, 'sdk': str(sdk), 'operation': operation, 'stop': stop, 'precommit': precommit, 'running': running, 'uncertain': uncertain}))
        with (root / f'process-{launch}.log').open('wb') as log:
            process = subprocess.Popen([str(executable)],
                env={**os.environ, 'ASG_CANDIDATE_CRASH_ROOT': str(root)}, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 150
                while not (root / f'launch-{launch}.json').exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise ValueError('Candidate app handshake failed')
                    time.sleep(0.02)
                # Writer creates exclusively, then flushes. Wait for process-independent
                # publication to finish before parsing; malformed data remains a refusal.
                while True:
                    try:
                        value = read_report(root, launch, nonce, operation, stop, precommit, running, uncertain)
                        break
                    except (json.JSONDecodeError, UnicodeDecodeError):
                        if time.monotonic() > deadline:
                            raise ValueError('Candidate report incomplete')
                        time.sleep(0.02)
                if inspect_bundle(bundle) != (executable, binary):
                    raise ValueError('Fixture binary changed before crash/reopen')
                if launch == 1:
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
    parser.add_argument('--operation', choices=OPERATIONS + ['all'], default='resolve')
    args = parser.parse_args()
    try:
        if args.operation == 'all':
            observations = [observe(args.bundle, args.sdk, operation, args.stop, args.precommit, args.running, args.uncertain) for operation in OPERATIONS]
            if len({item['bundleSha256'] for item in observations}) != 1:
                raise ValueError('Matrix binary changed')
            print(json.dumps({'matrix': observations}))
        else:
            print(json.dumps(observe(args.bundle, args.sdk, args.operation, args.stop, args.precommit, args.running, args.uncertain)))
    except (ValueError, OSError, subprocess.TimeoutExpired):
        parser.exit(2, 'Candidate crash fixture refused or failed; artifacts retained.\n')


if __name__ == '__main__':
    main()
