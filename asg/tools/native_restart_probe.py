# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Inspect, then optionally launch an explicitly supplied disposable Mac probe twice.

Does not build, install, download, alter production configuration or signal saved PIDs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys
import tempfile

BUNDLE = 'com.arsinha.asg.restartfixture'


def inspect_bundle(bundle):
    bundle = Path(bundle).absolute()
    if bundle.resolve(strict=True) != bundle or bundle.suffix != '.app':
        raise ValueError('Canonical disposable app bundle required')
    plist = bundle / 'Contents/Info.plist'
    if plist.is_symlink() or not plist.is_file():
        raise ValueError('Regular Info.plist required')
    metadata = plistlib.loads(plist.read_bytes())
    if not isinstance(metadata, dict):
        raise ValueError('Bundle metadata object required')
    name = metadata.get('CFBundleExecutable')
    if metadata.get('CFBundleIdentifier') != BUNDLE or not isinstance(name, str) or Path(name).name != name:
        raise ValueError('Disposable bundle identity required')
    executable = bundle / 'Contents/MacOS' / name
    if executable.resolve(strict=True) != executable or not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError('Canonical executable required')
    digest = hashlib.sha256()
    for root, dirs, files in os.walk(bundle, followlinks=False):
        dirs.sort()
        for name in sorted(dirs + files):
            item = Path(root) / name
            if item.is_symlink():
                if not item.resolve(strict=True).is_relative_to(bundle):
                    raise ValueError('External bundle link refused')
                digest.update(item.relative_to(bundle).as_posix().encode() + b'\0' + os.readlink(item).encode())
        for name in sorted(files):
            item = Path(root) / name
            if not item.is_symlink():
                digest.update(item.relative_to(bundle).as_posix().encode() + b'\0')
                with item.open('rb') as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        digest.update(chunk)
    return executable, digest.hexdigest()


def run_probe(bundle):
    if sys.platform != 'darwin':
        raise ValueError('Mac probe only')
    executable, identity = inspect_bundle(bundle)
    root = Path(tempfile.mkdtemp(prefix='asg-restart-probe-')).resolve()
    nonce = secrets.token_hex(16)
    reports = []
    for launch in (1, 2):
        if inspect_bundle(bundle) != (executable, identity):
            raise ValueError('Probe binary changed')
        (root / 'challenge.json').write_text(json.dumps({'nonce': nonce, 'launch': launch}))
        # subprocess.run retains its own live handle and kills/reaps that child on timeout.
        completed = subprocess.run([str(executable)], env={**os.environ, 'ASG_RESTART_PROBE_ROOT': str(root)},
                                   capture_output=True, timeout=30)
        if completed.returncode != 0:
            raise ValueError('Disposable app probe failed')
        report = root / f'launch-{launch}.json'
        if report.is_symlink() or not report.is_file() or report.stat().st_size > 4096:
            raise ValueError('Invalid probe report')
        value = json.loads(report.read_text())
        if (not isinstance(value, dict) or set(value) != {'version', 'bundle', 'nonce', 'launch', 'support', 'preferencesPersisted'} or
                type(value.get('version')) is not int or type(value.get('launch')) is not int or
                not isinstance(value.get('support'), str) or value.get('version') != 1 or value.get('bundle') != BUNDLE or value.get('nonce') != nonce or
                value.get('launch') != launch or value.get('preferencesPersisted') is not (launch == 2) or
                Path(value.get('support', '')).name != BUNDLE):
            raise ValueError('Probe observation mismatch')
        reports.append(value)
    if reports[0]['support'] != reports[1]['support'] or inspect_bundle(bundle) != (executable, identity):
        raise ValueError('Probe identity changed across launch')
    domain = subprocess.run(['/usr/bin/defaults', 'read', BUNDLE, f'flutter.asg.restartProbe.{nonce}'],
                            capture_output=True, text=True, timeout=5)
    if domain.returncode != 0 or domain.stdout.strip() != nonce:
        raise ValueError('Fixture preference domain mismatch')
    return {'bundleSha256': identity, 'controlRoot': str(root), 'observations': reports,
            'limitation': 'Normal native process persistence only; no app crash/recovery acceptance.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', required=True)
    parser.add_argument('--run', action='store_true')
    args = parser.parse_args()
    try:
        if args.run:
            result = run_probe(args.bundle)
        else:
            executable, identity = inspect_bundle(args.bundle)
            result = {'executable': str(executable), 'bundleSha256': identity, 'launched': False}
        print(json.dumps(result))
    except (ValueError, OSError, subprocess.TimeoutExpired, plistlib.InvalidFileException):
        parser.exit(2, 'Native probe refused or failed; retained artifacts were not removed.\n')


if __name__ == '__main__':
    main()
