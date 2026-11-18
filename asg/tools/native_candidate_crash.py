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


def read_report(root, launch, nonce):
    report = root / f'launch-{launch}.json'
    if report.is_symlink() or not report.is_file() or report.stat().st_size > 4096:
        raise ValueError('Invalid candidate report')
    value = json.loads(report.read_text())
    if (not isinstance(value, dict) or type(value.get('version')) is not int or value['version'] != 1 or
            type(value.get('launch')) is not int or value['launch'] != launch or value.get('nonce') != nonce or
            value.get('dispatch') != f'candidate-restart-{nonce}-1:3'):
        raise ValueError('Candidate report identity mismatch')
    if launch == 1:
        if value.get('readyForCrash') is not True:
            raise ValueError('Crash handshake missing')
    elif (value.get('interrupted') is not True or type(value.get('retainedResolveExit')) is not int or
          value['retainedResolveExit'] != 0 or value.get('cleanup') != 'unknown' or
          any(value.get(key) is not True for key in ('journalUnchanged', 'sourcesUnchanged', 'workingUnchanged', 'viewRendered')) or
          value.get('executionPhase') != 'executing'):
        raise ValueError('Recovery observation mismatch')
    return value


def observe(bundle, sdk):
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
        (root / 'challenge.json').write_text(json.dumps({'nonce': nonce, 'launch': launch, 'sdk': str(sdk)}))
        with (root / f'process-{launch}.log').open('wb') as log:
            process = subprocess.Popen([str(executable)],
                env={**os.environ, 'ASG_CANDIDATE_CRASH_ROOT': str(root)}, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 35
                while not (root / f'launch-{launch}.json').exists():
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise ValueError('Candidate app handshake failed')
                    time.sleep(0.02)
                # Writer creates exclusively, then flushes. Wait for process-independent
                # publication to finish before parsing; malformed data remains a refusal.
                while True:
                    try:
                        value = read_report(root, launch, nonce)
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
    return {'bundleSha256': binary, 'controlRoot': str(root), 'observations': observations,
            'limitation': 'Fixed resolve fixture only; no automatic reconciliation or full multi-operation acceptance.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--sdk', required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(observe(args.bundle, args.sdk)))
    except (ValueError, OSError, subprocess.TimeoutExpired):
        parser.exit(2, 'Candidate crash fixture refused or failed; artifacts retained.\n')


if __name__ == '__main__':
    main()
