# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Prepare an original immutable baseline using trusted bundled primitives only.

This protocol does not apply a replacement, execute repository code, establish
current app consent or authenticate repository origin. The native caller owns
its process group, durable admission and recovery when delivery is uncertain.
"""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import posixpath
import re
import signal
import stat
import subprocess
import sys
import time

REQUEST_LIMIT = RESPONSE_LIMIT = 32 * 1024
PENDING = '.asg-imported-copy-pending'
_RUN = re.compile(r'asg-self-candidate-[a-f0-9]{8}', re.ASCII)
_SHA = re.compile(r'[a-f0-9]{64}', re.ASCII)
_OID = re.compile(r'[a-f0-9]{40}', re.ASCII)
_KEYS = {'version', 'scope', 'attempt_id', 'root', 'python', 'destination',
         'commit', 'tree', 'manifest_sha256', 'manifest_files', 'context_sha256',
         'plan_sha256', 'proposal_sha256', 'history_sha256', 'selected_files'}


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Invalid copy request.')
        result[key] = value
    return result


def _path(value):
    return (isinstance(value, str) and value.startswith('/') and value != '/'
            and not value.startswith('//') and posixpath.normpath(value) == value
            and len(value.encode('utf-8')) <= 4096
            and not any(ord(c) < 32 or 127 <= ord(c) <= 159 for c in value)
            and not any(part.lower().endswith('.app') for part in value.split('/')))


def _inside(root, value):
    root, value = root.casefold(), value.casefold()
    return value == root or value.startswith(root + '/')


def request(raw, observer):
    if not isinstance(raw, str) or len(raw.encode('utf-8')) > REQUEST_LIMIT:
        raise ValueError('Invalid copy request.')
    data = json.loads(raw, object_pairs_hook=_unique)
    if (not isinstance(data, dict) or set(data) != _KEYS
            or type(data['version']) is not int or data['version'] != 1
            or data['scope'] != 'imported-commit-copy-request'
            or not all(_path(data[k]) for k in ('root', 'python', 'destination'))
            or not isinstance(data['attempt_id'], str)
            or re.fullmatch(r'[a-f0-9]{32}', data['attempt_id'], re.ASCII) is None
            or data['attempt_id'] == '0' * 32
            or any(not isinstance(data[k], str) or _OID.fullmatch(data[k]) is None
                   or data[k] == '0' * 40 for k in ('commit', 'tree'))
            or any(not isinstance(data[k], str) or _SHA.fullmatch(data[k]) is None
                   for k in ('manifest_sha256', 'context_sha256', 'plan_sha256',
                             'proposal_sha256', 'history_sha256'))
            or type(data['manifest_files']) is not int
            or not 1 <= data['manifest_files'] <= 2048
            or _inside(data['root'], data['destination'])
            or _inside(data['root'], data['python'])
            or _inside(data['destination'], data['python'])):
        raise ValueError('Invalid copy request.')
    files = data['selected_files']
    if not isinstance(files, list) or not 1 <= len(files) <= 4:
        raise ValueError('Invalid copy request.')
    total = 0
    names = []
    for file in files:
        if (not isinstance(file, dict)
                or set(file) != {'path', 'mode', 'git_blob', 'sha256', 'byte_length'}
                or file['mode'] not in ('100644', '100755')
                or not isinstance(file['git_blob'], str)
                or _OID.fullmatch(file['git_blob']) is None
                or file['git_blob'] == '0' * 40
                or not isinstance(file['sha256'], str)
                or _SHA.fullmatch(file['sha256']) is None
                or type(file['byte_length']) is not int
                or not 0 <= file['byte_length'] <= 32768):
            raise ValueError('Invalid copy request.')
        total += file['byte_length']
        names.append(file['path'])
    observer.selection(names)
    if total > 65536 or len(files) > data['manifest_files']:
        raise ValueError('Invalid copy request.')
    return data


def _timestamp():
    now = datetime.datetime.now(datetime.timezone.utc)
    fraction = f'{now.microsecond:06d}'
    if fraction.endswith('000'):
        fraction = fraction[:3]
    return now.strftime('%Y-%m-%dT%H:%M:%S.') + fraction + 'Z'


def _response(data, digest, *, reason, run=None, fingerprint=None, files=None, size=None):
    prepared = reason is None
    value = {'version': 1, 'scope': 'imported-commit-copy',
             'request_sha256': digest, 'attempt_id': data['attempt_id'],
             'root': data['root'], 'destination': data['destination'],
             'commit': data['commit'], 'tree': data['tree'],
             'manifest_sha256': data['manifest_sha256'],
             'manifest_files': data['manifest_files'],
             'status': 'prepared' if prepared else 'refused', 'reason': reason,
             'run_name': run,
             'copy_path': str(Path(data['destination']) / run / ('source-' + data['commit'])) if prepared else None,
             'fingerprint': fingerprint, 'files': files, 'bytes': size,
             'source_verified': False, 'working_tree': 'unknown', 'conflict': 'unknown',
             'recorded_at': _timestamp()}
    if len(json.dumps(value, separators=(',', ':')).encode()) > RESPONSE_LIMIT:
        raise ValueError('Copy response exceeds limits.')
    return value


def prepare_copy(raw, candidate, observer):
    data = request(raw, observer)
    digest = hashlib.sha256(raw.encode('utf-8')).hexdigest()
    run = None
    try:
        candidate.check_stop()
        root, parent = Path(data['root']), Path(data['destination'])
        # Pin every ancestor. Replaced/linked inputs are not silently canonicalized.
        descriptors = []
        try:
            for directory in (root, parent):
                descriptor = candidate.open_directory_no_links(directory)
                descriptors.append(descriptor)
                candidate.require_directory_identity(directory, descriptor)
            observed = observer.observe(str(root), data['commit'],
                                        [f['path'] for f in data['selected_files']],
                                        stopped=lambda: candidate._stop_requested)
            candidate.check_stop()
            if (observed['status'] != 'observed'
                    or any(observed[k] != data[k] for k in ('root', 'commit', 'tree', 'manifest_sha256', 'manifest_files'))
                    or [{k: f[k] for k in ('path', 'mode', 'git_blob', 'sha256', 'byte_length')}
                        for f in observed['files']] != data['selected_files']):
                return _response(data, digest, reason='input_changed')
            for directory, descriptor in zip((root, parent), descriptors):
                candidate.require_directory_identity(directory, descriptor)
            try:
                source_info, parent_info = (os.fstat(fd) for fd in descriptors)
                ready = candidate.prepare(
                    root, data['commit'], parent,
                    expected_source_identity=(source_info.st_dev, source_info.st_ino),
                    expected_parent_identity=(parent_info.st_dev, parent_info.st_ino))
            except candidate.PreparationRunError as error:
                run = error.run_name
                raise
            run = ready.parent.name
            if (_RUN.fullmatch(run) is None or ready.parent.parent != parent
                    or ready.name != 'source-' + data['commit']):
                raise ValueError('Unexpected prepared directory.')
            holder = candidate.open_directory_no_links(ready.parent)
            try:
                # Keep the extra full-manifest verification explicitly pending.
                fd = os.open(PENDING, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             0o600, dir_fd=holder)
                with os.fdopen(fd, 'w') as marker:
                    marker.write(digest)
                    marker.flush()
                    os.fsync(marker.fileno())
                selected = {f['path']: f for f in data['selected_files']}
                sizes = 0
                found = set()
                def check(relative, content, mode):
                    nonlocal sizes
                    if content is None:
                        return
                    sizes += len(content)
                    if relative in selected:
                        file = selected[relative]
                        git_blob = hashlib.sha1(b'blob ' + str(len(content)).encode() + b'\0' + content).hexdigest()
                        if (len(content) != file['byte_length']
                                or hashlib.sha256(content).hexdigest() != file['sha256']
                                or git_blob != file['git_blob']
                                or ('100755' if mode & stat.S_IXUSR else '100644') != file['mode']):
                            raise ValueError('Selected copy bytes changed.')
                        found.add(relative)
                fingerprint, index = candidate.scan_candidate(ready, sink=check,
                                                              deadline=time.monotonic() + 10)
                manifest = [{'path': name, 'mode': mode, 'git_blob': blob}
                            for name, (mode, blob) in sorted(index.items())]
                manifest_digest = hashlib.sha256(json.dumps(
                    manifest, sort_keys=True, separators=(',', ':')).encode('ascii')).hexdigest()
                if (len(index) != data['manifest_files'] or found != set(selected)
                        or manifest_digest != data['manifest_sha256']):
                    raise ValueError('Complete copy manifest changed.')
                candidate.check_stop()
                for directory, descriptor in zip((root, parent), descriptors):
                    candidate.require_directory_identity(directory, descriptor)
                candidate.require_directory_identity(ready.parent, holder)
                # A second bounded scan catches mutation after manifest observation.
                if candidate.fingerprint(ready) != fingerprint:
                    raise ValueError('Prepared copy changed.')
                candidate.check_stop()
                marker = os.open(PENDING, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=holder)
                try:
                    info = os.fstat(marker)
                    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
                            or os.read(marker, 65) != digest.encode('ascii')):
                        raise ValueError('Copy marker changed.')
                finally:
                    os.close(marker)
                os.unlink(PENDING, dir_fd=holder)
                return _response(data, digest, reason=None, run=run,
                                 fingerprint=fingerprint, files=len(index), size=sizes)
            finally:
                os.close(holder)
        finally:
            for descriptor in descriptors:
                os.close(descriptor)
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt):
        return _response(data, digest,
                         reason='stopped' if candidate._stop_requested else 'copy_unavailable', run=run)


def _bundled(name):
    file = Path(__file__).with_name(name + '.py')
    spec = importlib.util.spec_from_file_location(name, file)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def main(argv):
    try:
        if len(argv) != 1:
            raise ValueError()
        source = Path(argv[0])
        descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(descriptor)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > REQUEST_LIMIT:
                raise ValueError()
            raw = os.read(descriptor, REQUEST_LIMIT + 1).decode('utf-8')
            if len(raw.encode('utf-8')) != info.st_size:
                raise ValueError()
        finally:
            os.close(descriptor)
        candidate = _bundled('prepare_self_candidate')
        observer = _bundled('imported_commit_source')
        signal.signal(signal.SIGTERM, candidate.request_stop)
        value = prepare_copy(raw, candidate, observer)
        print(json.dumps(value, separators=(',', ':')))
        return 0 if value['status'] == 'prepared' else 2
    except (OSError, ValueError, UnicodeError, RecursionError, TypeError):
        print('Immutable baseline copy unavailable. Inspect the selected destination.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
