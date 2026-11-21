# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Bounded literal working-file/index comparisons; never Git status or authority."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time


def load_index():
    name = 'asg_workfile_index'
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name('imported_index.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


index = load_index()
metadata = index.metadata
REQUEST_LIMIT = 16 * 1024
RESPONSE_LIMIT = 32 * 1024
FILE_LIMIT = 32 * 1024
AGGREGATE_LIMIT = 64 * 1024


class Refusal(Exception):
    def __init__(self, reason):
        self.reason = reason


def selection(paths):
    if not isinstance(paths, list) or not 1 <= len(paths) <= 4:
        return False
    previous = None
    seen = set()
    for name in paths:
        if not isinstance(name, str) or not name.isascii() or not 1 <= len(name) <= 512:
            return False
        parts = name.split('/')
        if (not 2 <= len(parts) <= 16 or parts[0] not in ('lib', 'test')
                or not parts[-1].endswith('.dart')
                or any(p in ('.', '..') or re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', p, re.ASCII) is None for p in parts)
                or name.lower() in seen or (previous is not None and name <= previous)):
            return False
        seen.add(name.lower())
        previous = name
    return True


def hex_label(value, length):
    return isinstance(value, str) and re.fullmatch(r'[a-f0-9]{%d}' % length, value, re.ASCII) is not None


def request(raw):
    if not isinstance(raw, str) or len(raw.encode('utf-8')) > REQUEST_LIMIT:
        raise ValueError()
    d = json.loads(raw, object_pairs_hook=index.unique)
    if (not isinstance(d, dict) or set(d) != {'version', 'scope', 'root', 'python', 'comparison_id',
            'index_request_sha256', 'index_observation_sha256', 'index_sha256', 'index_byte_length', 'selected_files'}
            or type(d['version']) is not int or d['version'] != 1
            or d['scope'] != 'imported-workfile-comparison-request'
            or not all(hex_label(d[k], 64) for k in ('index_request_sha256', 'index_observation_sha256', 'index_sha256'))
            or type(d['index_byte_length']) is not int or not 32 <= d['index_byte_length'] <= index.INDEX_LIMIT
            or not isinstance(d['selected_files'], list) or not 1 <= len(d['selected_files']) <= 4):
        raise ValueError()
    index.request(json.dumps({'version': 1, 'scope': 'imported-index-read-request',
                             'root': d['root'], 'python': d['python'], 'read_id': d['comparison_id']}))
    minimum = 32
    for item in d['selected_files']:
        if (not isinstance(item, dict) or set(item) != {'path', 'mode', 'oid'}
                or not isinstance(item['path'], str) or item['mode'] not in ('100644', '100755')
                or not hex_label(item['oid'], 40) or item['oid'] == '0' * 40):
            raise ValueError()
        minimum += ((62 + len(item['path']) + 1 + 7) // 8) * 8
    if not selection([f['path'] for f in d['selected_files']]) or minimum > d['index_byte_length']:
        raise ValueError()
    return d


def observe(raw):
    d = request(raw)
    reader, files = None, []
    status, reason = 'refused', 'unavailable'
    index._deadline = time.monotonic() + 5
    try:
        index.check()
        if not metadata.SUPPORTED_HOST:
            raise Refusal('unavailable')
        python = index.python_identity(d)
        reader = index.Reader()
        root = reader.root(d['root'])
        try:
            reader.git = reader.directory(root, '.git')
            reader.layout()
            content = reader.read(reader.git, 'index', index.INDEX_LIMIT)
        except FileNotFoundError:
            raise Refusal('unsupported_index') from None
        if (len(content) != d['index_byte_length']
                or hashlib.sha256(content).hexdigest() != d['index_sha256']):
            raise Refusal('index_changed')
        entries, _ = index.decode(content)
        declared = {entry['path']: entry for entry in entries}
        total = 0
        for expected in d['selected_files']:
            index.check()
            name = expected['path']
            if name not in declared:
                raise Refusal('unindexed')
            if expected != declared[name]:
                raise Refusal('index_changed')
            parts = name.split('/')
            parent = root
            try:
                for component in parts[:-1]:
                    parent = reader.directory(parent, component)
                data = reader.read(parent, parts[-1], FILE_LIMIT)
            except FileNotFoundError:
                raise Refusal('source_missing') from None
            total += len(data)
            if total > AGGREGATE_LIMIT:
                raise Refusal('bounds')
            mode = os.fstat(reader.files[-1][2]).st_mode
            executable = bool(mode & 0o111)
            raw_blob = hashlib.sha1(b'blob ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()
            files.append({'path': name, 'byte_length': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
                          'raw_blob': raw_blob, 'executable': executable,
                          'raw_blob_matches': raw_blob == expected['oid'],
                          'executable_matches': executable == (expected['mode'] == '100755')})
        reader.validate()
        if index.python_identity(d) != python:
            raise Refusal('changed')
        index.check()
        status, reason = 'observed', None
    except Refusal as error:
        reason = error.reason
    except index.Refusal as error:
        if error.status == 'stopped':
            status, reason = 'stopped', 'stopped'
        elif error.status == 'changed':
            reason = 'changed'
        elif error.reason == 'bounds':
            reason = 'bounds'
        elif error.status == 'unsupported' or error.status == 'invalid':
            reason = 'unsupported_index'
        else:
            reason = 'unavailable'
    except metadata.Refusal as error:
        reason = ('changed' if error.status == 'changed' else
                  'bounds' if error.reason == 'metadata_too_large' else 'unsafe_source')
    except (OSError, ValueError, TypeError, UnicodeError, KeyboardInterrupt):
        reason = 'unavailable'
    finally:
        if reader is not None:
            reader.close()
        if index._stop_requested:
            status, reason = 'stopped', 'stopped'
        elif index._deadline is not None and time.monotonic() >= index._deadline:
            status, reason = 'refused', 'unavailable'
        index._deadline = None
    if status != 'observed':
        files = []
    result = {'version': 1, 'scope': 'imported-workfile-comparison',
              'request_sha256': hashlib.sha256(raw.encode('utf-8')).hexdigest(),
              'comparison_id': d['comparison_id'], 'root': d['root'],
              'index_sha256': d['index_sha256'] if status == 'observed' else None,
              'status': status, 'reason': reason, 'files': files,
              'git_state_verified': False, 'head_membership': 'unknown', 'filters': 'unknown',
              'working_tree': 'unknown', 'commit_authorized': False, 'mutation_authorized': False,
              'recorded_at': index.timestamp()}
    if len(json.dumps(result, ensure_ascii=False, separators=(',', ':')).encode('utf-8')) > RESPONSE_LIMIT:
        result.update(status='refused', reason='bounds', files=[], index_sha256=None)
    return result


def main(argv):
    try:
        os.umask(0o077)
        if len(argv) != 1 or not metadata.SUPPORTED_HOST:
            raise ValueError()
        signal.signal(signal.SIGTERM, index.stop)
        fd = os.open(argv[0], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > REQUEST_LIMIT:
                raise ValueError()
            raw = os.read(fd, REQUEST_LIMIT + 1).decode('utf-8')
            if len(raw.encode('utf-8')) != before.st_size or metadata.signature(os.fstat(fd)) != metadata.signature(before):
                raise ValueError()
        finally:
            os.close(fd)
        result = observe(raw)
        print(json.dumps(result, ensure_ascii=False, separators=(',', ':')))
        return 0 if result['status'] == 'observed' else 2
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
        print('Selected working-file comparison unavailable.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
