# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Bounded literal index declarations. Never Git status, commands or authority."""
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import stat
import struct
import sys
import time

REQUEST_LIMIT = 16 * 1024
INDEX_LIMIT = 256 * 1024
RESPONSE_LIMIT = 512 * 1024
_stop_requested = False
_deadline = None


def metadata_module():
    name = 'asg_imported_index_metadata'
    spec = importlib.util.spec_from_file_location(
        name, Path(__file__).with_name('git_head_metadata.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


metadata = metadata_module()


class Refusal(Exception):
    def __init__(self, status, reason):
        self.status, self.reason = status, reason


def stop(_signal, _frame):
    global _stop_requested
    _stop_requested = True


def check():
    if _stop_requested:
        raise Refusal('stopped', 'stopped')
    if _deadline is not None and time.monotonic() >= _deadline:
        raise Refusal('unavailable', 'read_unavailable')


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate member.')
        result[key] = value
    return result


def valid_path(value):
    return (isinstance(value, str) and value.startswith('/') and value != '/'
            and os.path.normpath(value) == value
            and len(value.encode('utf-8')) <= 4096
            and len(value.split('/')) <= 129
            and not any(ord(c) < 32 or ord(c) == 127 for c in value)
            and not any(p.lower().endswith('.app') for p in value.split('/')))


def inside(parent, child):
    parent, child = parent.casefold(), child.casefold()
    return child == parent or child.startswith(parent + '/')


def request(raw):
    if not isinstance(raw, str) or len(raw.encode('utf-8')) > REQUEST_LIMIT:
        raise ValueError('Invalid request.')
    data = json.loads(raw, object_pairs_hook=unique)
    if (not isinstance(data, dict) or set(data) != {
            'version', 'scope', 'root', 'python', 'read_id'}
            or type(data['version']) is not int or data['version'] != 1
            or data['scope'] != 'imported-index-read-request'
            or not valid_path(data['root']) or not valid_path(data['python'])
            or inside(data['root'], data['python'])
            or inside(data['python'], data['root'])
            or not isinstance(data['read_id'], str)
            or re.fullmatch(r'[a-f0-9]{32}', data['read_id'], re.ASCII) is None
            or data['read_id'] == '0' * 32):
        raise ValueError('Invalid request.')
    return data


def python_identity(data):
    actual = str(Path(sys.executable).resolve(strict=True))
    configured = str(Path(data['python']).resolve(strict=True))
    if configured != actual or inside(data['root'], actual):
        raise Refusal('unavailable', 'invalid_request')
    return actual


class Reader(metadata.Reader):
    """Index layout only. Packed refs are unrelated and are never opened."""
    def directory(self, parent, name):
        check()
        return super().directory(parent, name)

    def read(self, parent, name, limit):
        check()
        value = super().read(parent, name, limit)
        check()
        return value

    def layout(self, changed=False):
        check()
        for name in ('commondir', 'gitdir', 'reftable'):
            try:
                os.stat(name, dir_fd=self.git, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise Refusal('changed' if changed else 'unsupported',
                          'layout_changed' if changed else 'layout')
        try:
            os.stat('index.lock', dir_fd=self.git, follow_symlinks=False)
        except FileNotFoundError:
            return
        raise Refusal('changed', 'lock_changed')

    def validate(self):
        self.layout(changed=True)
        super().validate()
        check()


def decode(raw):
    check()
    if not 32 <= len(raw) <= INDEX_LIMIT:
        raise Refusal('invalid', 'bounds')
    if raw[:4] != b'DIRC':
        raise Refusal('invalid', 'malformed')
    if hashlib.sha1(raw[:-20]).digest() != raw[-20:]:
        raise Refusal('invalid', 'checksum')
    version, count = struct.unpack('!II', raw[4:12])
    if version != 2:
        raise Refusal('unsupported', 'format')
    if count > 2048:
        raise Refusal('invalid', 'bounds')
    pos, end = 12, len(raw) - 20
    entries, seen, previous = [], set(), None
    for _ in range(count):
        check()
        start = pos
        if pos + 62 > end:
            raise Refusal('invalid', 'malformed')
        mode = struct.unpack('!I', raw[pos + 24:pos + 28])[0]
        oid = raw[pos + 40:pos + 60]
        flags = struct.unpack('!H', raw[pos + 60:pos + 62])[0]
        if mode not in (0o100644, 0o100755) or flags & 0xf000 or oid == b'\0' * 20:
            raise Refusal('unsupported', 'entry')
        pos += 62
        zero = raw.find(b'\0', pos, min(end, pos + 1025))
        if zero < 0:
            raise Refusal('invalid', 'path')
        name = raw[pos:zero]
        if (not name or len(name) != flags & 0xfff
                or re.fullmatch(rb'[A-Za-z0-9_. @+()/\-]+', name) is None
                or any(p.lower() in (b'', b'.', b'..', b'.git') for p in name.split(b'/'))
                or name.lower() in seen or (previous is not None and name <= previous)):
            raise Refusal('invalid', 'path')
        seen.add(name.lower())
        previous = name
        pos = start + ((zero + 1 - start + 7) // 8) * 8
        if pos > end or any(raw[zero:pos]):
            raise Refusal('invalid', 'malformed')
        entries.append({'path': name.decode('ascii'), 'mode': format(mode, 'o'),
                        'oid': oid.hex()})
    caches = []
    while pos < end:
        check()
        if pos + 8 > end:
            raise Refusal('invalid', 'malformed')
        signature, size = raw[pos:pos + 4], struct.unpack('!I', raw[pos + 4:pos + 8])[0]
        pos += 8
        if size > end - pos:
            raise Refusal('invalid', 'bounds')
        if signature != b'TREE' or caches:
            raise Refusal('unsupported', 'extension')
        # The cache payload is opaque. Never use its tree labels or claims.
        caches.append('TREE')
        pos += size
    return entries, caches


def timestamp():
    now = datetime.datetime.now(datetime.timezone.utc)
    fraction = f'{now.microsecond:06d}'
    if fraction.endswith('000'):
        fraction = fraction[:3]
    return now.strftime('%Y-%m-%dT%H:%M:%S.') + fraction + 'Z'


def observe(raw):
    global _deadline
    data = request(raw)
    status, reason, content, entries, caches = 'unavailable', 'read_unavailable', None, [], []
    reader = None
    _deadline = time.monotonic() + 5
    try:
        check()
        if not metadata.SUPPORTED_HOST:
            raise Refusal('unsupported', 'host')
        interpreter = python_identity(data)
        reader = Reader()
        root = reader.root(data['root'])
        try:
            reader.git = reader.directory(root, '.git')
        except (FileNotFoundError, NotADirectoryError):
            raise Refusal('unsupported', 'layout') from None
        reader.layout()
        try:
            content = reader.read(reader.git, 'index', INDEX_LIMIT)
        except FileNotFoundError:
            raise Refusal('invalid', 'missing_index') from None
        entries, caches = decode(content)
        reader.validate()
        if python_identity(data) != interpreter:
            raise Refusal('changed', 'metadata_changed')
        check()
        status, reason = 'observed', None
    except Refusal as error:
        status, reason = error.status, error.reason
    except metadata.Refusal as error:
        if error.status == 'changed':
            status, reason = 'changed', 'metadata_changed'
        elif error.reason == 'metadata_too_large':
            status, reason = 'invalid', 'bounds'
        else:
            status, reason = 'unsupported', 'layout'
    except (OSError, ValueError, TypeError, UnicodeError, KeyboardInterrupt):
        status, reason = ('stopped', 'stopped') if _stop_requested else ('unavailable', 'read_unavailable')
    finally:
        if reader is not None:
            reader.close()
        if _stop_requested:
            status, reason = 'stopped', 'stopped'
        elif _deadline is not None and time.monotonic() >= _deadline:
            status, reason = 'unavailable', 'read_unavailable'
        _deadline = None
    if status != 'observed':
        content, entries, caches = None, [], []
    value = {'version': 1, 'scope': 'imported-index-observation',
             'request_sha256': hashlib.sha256(raw.encode('utf-8')).hexdigest(),
             'read_id': data['read_id'], 'root': data['root'], 'status': status,
             'reason': reason, 'format': 'index-v2-sha1' if content is not None else None,
             'index_sha256': hashlib.sha256(content).hexdigest() if content is not None else None,
             'index_byte_length': len(content) if content is not None else None,
             'optional_caches': caches, 'entries': entries, 'git_state_verified': False,
             'working_tree': 'unknown', 'head_membership': 'unknown',
             'commit_authorized': False, 'mutation_authorized': False, 'recorded_at': timestamp()}
    if len(json.dumps(value, ensure_ascii=False, separators=(',', ':')).encode('utf-8')) > RESPONSE_LIMIT:
        value.update(status='invalid', reason='bounds', format=None, index_sha256=None,
                     index_byte_length=None, optional_caches=[], entries=[])
    return value


def main(argv):
    try:
        os.umask(0o077)
        if len(argv) != 1 or not metadata.SUPPORTED_HOST:
            raise ValueError()
        signal.signal(signal.SIGTERM, stop)
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
        print('Original-index observation unavailable.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
