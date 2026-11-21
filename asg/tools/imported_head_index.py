# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Explicit bounded declared-object reads. Never Git status or write authority."""
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
import zlib


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


index = load('asg_head_index', 'imported_index.py')
parser = load('asg_head_objects', 'imported_commit_source.py')
metadata = index.metadata
REQUEST_LIMIT = 16384
RESPONSE_LIMIT = 32768
OBJECT_LIMIT = 262144
OBJECT_COUNT = 70
PACKED_LIMIT = 262144
PACKED_COUNT = 2048
PACKED_HEADER = b'# pack-refs with: peeled fully-peeled sorted \n'
OBJECT_PROFILE = 'bounded-loose-pack2-index2-v1'


class Refusal(Exception):
    def __init__(self, reason):
        self.reason = reason


def label(value, size):
    return isinstance(value, str) and re.fullmatch(r'[a-f0-9]{%d}' % size, value, re.ASCII) is not None


def request(raw):
    if not isinstance(raw, str) or len(raw.encode('utf-8')) > REQUEST_LIMIT:
        raise ValueError()
    d = json.loads(raw, object_pairs_hook=index.unique)
    legacy_keys = {'version', 'scope', 'root', 'python', 'read_id', 'workfile_request_sha256',
                   'workfile_observation_sha256', 'index_sha256', 'index_byte_length', 'selected_files'}
    if not isinstance(d, dict) or type(d.get('version')) is not int:
        raise ValueError()
    if (d['version'] == 1 and set(d) != legacy_keys
            or d['version'] == 2 and (set(d) != legacy_keys | {'object_profile'} or d.get('object_profile') != OBJECT_PROFILE)
            or d['version'] not in (1, 2)):
        raise ValueError()
    if (d['scope'] != 'imported-head-index-read-request'
            or not all(label(d[k], 64) for k in ('workfile_request_sha256', 'workfile_observation_sha256', 'index_sha256'))
            or type(d['index_byte_length']) is not int or not 32 <= d['index_byte_length'] <= index.INDEX_LIMIT
            or not isinstance(d['selected_files'], list) or not 1 <= len(d['selected_files']) <= 4):
        raise ValueError()
    index.request(json.dumps({'version': 1, 'scope': 'imported-index-read-request',
                             'root': d['root'], 'python': d['python'], 'read_id': d['read_id']}))
    minimum, total, paths = 32, 0, []
    for f in d['selected_files']:
        if (not isinstance(f, dict) or set(f) != {'path', 'index_mode', 'index_oid', 'working_sha256',
                'working_byte_length', 'working_raw_blob', 'working_executable'}
                or not isinstance(f['path'], str) or f['index_mode'] not in ('100644', '100755')
                or not parser.valid_oid(f['index_oid']) or not parser.valid_oid(f['working_raw_blob'])
                or not label(f['working_sha256'], 64) or type(f['working_executable']) is not bool
                or type(f['working_byte_length']) is not int or not 0 <= f['working_byte_length'] <= 32768):
            raise ValueError()
        paths.append(f['path'])
        minimum += ((62 + len(f['path']) + 1 + 7) // 8) * 8
        total += f['working_byte_length']
    parser.selection(paths)
    if paths != sorted(paths) or minimum > d['index_byte_length'] or total > 65536:
        raise ValueError()
    return d


def packed_references(data):
    """One explicit LF-only table subset, never Git namespace authority."""
    index.check()
    if (len(data) > PACKED_LIMIT or not data.startswith(PACKED_HEADER) or not data.endswith(b'\n')
            or any((c < 32 and c != 10) or c == 127 for c in data)):
        raise Refusal('unsupported_layout')
    entries, seen, previous, pending = {}, set(), None, None
    try:
        for line in data[len(PACKED_HEADER):].split(b'\n')[:-1]:
            index.check()
            if line.startswith(b'^'):
                value = line[1:].decode('ascii')
                if pending is None or not pending.startswith('refs/tags/') or not parser.valid_oid(value):
                    raise Refusal('unsupported_layout')
                pending = None
                continue
            if len(entries) >= PACKED_COUNT or line.count(b' ') != 1:
                raise Refusal('unsupported_layout')
            oid, ref = line.decode('ascii').split(' ')
            if (not parser.valid_oid(oid) or not ref.startswith(('refs/heads/', 'refs/tags/', 'refs/remotes/'))
                    or not metadata.reference('refs/heads/' + ref[5:]) or ref.casefold() in seen
                    or previous is not None and ref <= previous):
                raise Refusal('unsupported_layout')
            entries[ref], previous, pending = oid, ref, ref
            seen.add(ref.casefold())
    except (UnicodeError, ValueError):
        raise Refusal('unsupported_layout') from None
    index.check()
    return entries


class Reader(index.Reader):
    def __init__(self):
        super().__init__()
        self.objects = self.ref_parent = self.ref_name = None
        self.reference_acquisition = None
        self.pack_store = None

    @staticmethod
    def present(parent, name):
        try:
            os.stat(name, dir_fd=parent, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False

    def layout(self, changed=False):
        super().layout(changed)
        # Literal packed tables are acquired once and held with the read set.
        # Config/filter/project commands are never evaluated.
        for name in ('shallow', 'config.worktree'):
            if self.present(self.git, name):
                raise Refusal('changed' if changed else 'unsupported_layout')
        if any(self.present(self.git, name) for name in ('HEAD.lock', 'packed-refs.lock')):
            raise Refusal('changed')
        if self.present(self.git, 'refs'):
            refs = self.directory(self.git, 'refs')
            if self.present(refs, 'replace'):
                raise Refusal('changed' if changed else 'unsupported_layout')
        if self.objects is not None and self.present(self.objects, 'info'):
            info = self.directory(self.objects, 'info')
            if any(self.present(info, n) for n in ('alternates', 'http-alternates')):
                raise Refusal('changed' if changed else 'unsupported_layout')
        if self.ref_parent is not None and self.present(self.ref_parent, self.ref_name + '.lock'):
            raise Refusal('changed')
        if self.pack_store is not None:
            self.pack_store.validate()


class Objects:
    def __init__(self, reader):
        self.reader = reader
        self.reader.objects = reader.directory(reader.git, 'objects')
        self.cache, self.bytes = {}, 0
        reader.layout()

    def read(self, kind, oid):
        index.check()
        if not parser.valid_oid(oid):
            raise Refusal('invalid_object')
        key = (kind, oid)
        if key in self.cache:
            return self.cache[key]
        if len(self.cache) >= OBJECT_COUNT:
            raise Refusal('bounds')
        limit = {'commit': 65536, 'tree': 65536, 'blob': 32768}[kind]
        try:
            parent = self.reader.directory(self.reader.objects, oid[:2])
            stored = self.reader.read(parent, oid[2:], 131072)
        except FileNotFoundError:
            # No pack, alternates, external process or lazy-fetch fallback.
            raise Refusal('missing_loose_object') from None
        decoder = zlib.decompressobj()
        expanded = decoder.decompress(stored, limit + 129)
        if (len(expanded) > limit + 128 or not decoder.eof or
                decoder.unconsumed_tail or decoder.unused_data):
            raise Refusal('invalid_object')
        header, separator, body = expanded.partition(b'\0')
        if not separator or len(body) > limit or header != kind.encode() + b' ' + str(len(body)).encode():
            raise Refusal('invalid_object')
        self.bytes += len(body)
        if self.bytes > OBJECT_LIMIT:
            raise Refusal('bounds')
        result = parser.verified_object(kind, oid, body)
        index.check()
        self.cache[key] = result
        return result

    def selected(self, tree, path):
        parts = path.split('/')
        for i, part in enumerate(parts):
            index.check()
            entries = parser.tree_entries(tree, self.read('tree', tree))
            entry = next((e for e in entries if e.name == part), None)
            if entry is None:
                return None
            if i == len(parts) - 1:
                if entry.mode not in ('100644', '100755'):
                    raise Refusal('unsupported_layout')
                self.read('blob', entry.oid)
                return entry
            if entry.mode != '40000':
                return None
            tree = entry.oid
        raise Refusal('invalid_object')



class PackedObjects(Objects):
    def __init__(self, reader):
        super().__init__(reader)
        # Load only for the new explicit request profile. Legacy requests keep
        # their original sibling assets and their loose-only behavior.
        self.pack = load('asg_head_pack_objects', 'imported_pack_objects.py')
        self.store = self.pack.PackStore(reader, index.check, parser.verified_object, metadata.signature)
        reader.pack_store = self.store

    def read(self, kind, oid):
        key = (kind, oid)
        if key in self.cache:
            return self.cache[key]
        if self.store.object_count >= OBJECT_COUNT:
            raise Refusal('bounds')
        try:
            result = super().read(kind, oid)
        except Refusal as error:
            if error.reason != 'missing_loose_object':
                raise
        else:
            self.store.record_loose(kind, oid, result)
            return result
        result = self.store.read(kind, oid)
        self.bytes += len(result)
        if self.bytes > OBJECT_LIMIT:
            raise Refusal('bounds')
        self.cache[key] = result
        return result


def declared_head(reader):
    try:
        head = metadata.line(reader.read(reader.git, 'HEAD', 4096), 'invalid_head')
        packed, packed_hash, packed_bytes = {}, None, None
        try:
            raw = reader.read(reader.git, 'packed-refs', PACKED_LIMIT)
            packed = packed_references(raw)
            packed_hash, packed_bytes = hashlib.sha256(raw).hexdigest(), len(raw)
        except FileNotFoundError:
            # Reader holds the missing name too; appearance invalidates completion.
            pass
        if head.startswith('ref: '):
            ref = head[5:]
            if not metadata.reference(ref):
                raise Refusal('unsupported_layout')
            parent = reader.git
            parts = ref.split('/')
            # Missing/indirect parent directories stay outside this initial subset.
            for part in parts[:-1]:
                parent = reader.directory(parent, part)
            reader.ref_parent, reader.ref_name = parent, parts[-1]
            reader.layout()
            try:
                oid = metadata.line(reader.read(parent, parts[-1], 256), 'invalid_ref')
                source = 'loose_ref'
            except FileNotFoundError:
                oid = packed.get(ref)
                source = 'packed_ref'
            form = 'symbolic'
        else:
            oid, form, ref, source = head, 'direct_oid', None, 'head'
    except FileNotFoundError:
        raise Refusal('unsupported_layout') from None
    if not parser.valid_oid(oid):
        raise Refusal('unsupported_layout')
    reader.reference_acquisition = {'source': source, 'packed_refs_sha256': packed_hash,
        'packed_refs_byte_length': packed_bytes,
        'packed_refs_entry_count': len(packed) if packed_hash is not None else None}
    return form, ref, oid


def observe(raw):
    d = request(raw)
    reader, objects, files = None, None, []
    status, reason, form, ref, head, tree = 'refused', 'unavailable', None, None, None, None
    index._deadline = time.monotonic() + 5
    try:
        index.check()
        if not metadata.SUPPORTED_HOST:
            raise Refusal('unsupported_layout')
        python = index.python_identity(d)
        reader = Reader()
        root = reader.root(d['root'])
        try:
            reader.git = reader.directory(root, '.git')
        except FileNotFoundError:
            raise Refusal('unsupported_layout') from None
        reader.layout()
        form, ref, head = declared_head(reader)
        objects = PackedObjects(reader) if d['version'] == 2 else Objects(reader)
        tree = parser.commit_tree(head, objects.read('commit', head))
        try:
            content = reader.read(reader.git, 'index', index.INDEX_LIMIT)
        except FileNotFoundError:
            raise Refusal('index_changed') from None
        if len(content) != d['index_byte_length'] or hashlib.sha256(content).hexdigest() != d['index_sha256']:
            raise Refusal('index_changed')
        entries, _ = index.decode(content)
        declared = {e['path']: e for e in entries}
        for expected in d['selected_files']:
            name = expected['path']
            if declared.get(name) != {'path': name, 'mode': expected['index_mode'], 'oid': expected['index_oid']}:
                raise Refusal('index_changed')
            leaf = objects.selected(tree, name)
            parent, parts = root, name.split('/')
            try:
                for part in parts[:-1]:
                    parent = reader.directory(parent, part)
                data = reader.read(parent, parts[-1], 32768)
            except FileNotFoundError:
                raise Refusal('working_file_changed') from None
            executable = bool(os.fstat(reader.files[-1][2]).st_mode & 0o111)
            blob = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
            if (len(data) != expected['working_byte_length'] or hashlib.sha256(data).hexdigest() != expected['working_sha256']
                    or blob != expected['working_raw_blob'] or executable != expected['working_executable']):
                raise Refusal('working_file_changed')
            files.append({'path': name, 'tree_oid': leaf.oid if leaf else None, 'tree_mode': leaf.mode if leaf else None,
                          'index_matches_tree': leaf is not None and (leaf.oid, leaf.mode) == (expected['index_oid'], expected['index_mode']),
                          'working_bytes_match_tree': leaf is not None and leaf.oid == blob,
                          'working_executable_matches_tree': leaf is not None and executable == (leaf.mode == '100755')})
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
        else:
            reason = 'changed' if error.status == 'changed' else 'bounds' if error.reason == 'bounds' else 'unsupported_layout'
    except metadata.Refusal as error:
        reason = 'changed' if error.status == 'changed' else 'bounds' if error.reason == 'metadata_too_large' else 'unsupported_layout'
    except (parser.InvalidCommitSource, zlib.error):
        reason = 'invalid_object'
    except (OSError, ValueError, TypeError, UnicodeError, KeyboardInterrupt) as error:
        if isinstance(objects, PackedObjects) and isinstance(error, objects.pack.PackReadError):
            reason = error.reason
        elif isinstance(objects, PackedObjects) and isinstance(error, objects.pack.PackFormatError):
            reason = 'invalid_object'
        else:
            reason = 'unavailable'
    finally:
        if reader is not None:
            reader.close()
        if index._stop_requested:
            status, reason = 'stopped', 'stopped'
        elif index._deadline is not None and time.monotonic() >= index._deadline:
            status, reason = 'refused', 'unavailable'
        index._deadline = None
    observed = status == 'observed'
    result = {'version': 3 if d['version'] == 2 else 2, 'scope': 'imported-head-index-observation',
            'request_sha256': hashlib.sha256(raw.encode('utf-8')).hexdigest(), 'read_id': d['read_id'], 'root': d['root'],
            'status': status, 'reason': reason, 'acquisition': (OBJECT_PROFILE if d['version'] == 2 else 'direct-loose-object-files') if observed else None,
            'reference_acquisition': reader.reference_acquisition if observed else None,
            'head_form': form if observed else None, 'declared_ref': ref if observed else None,
            'head_oid': head if observed else None, 'tree_oid': tree if observed else None,
            'index_sha256': d['index_sha256'] if observed else None,
            'object_count': (objects.store.object_count if d['version'] == 2 else len(objects.cache)) if observed else 0,
            'object_bytes': (objects.store.expanded_bytes if d['version'] == 2 else objects.bytes) if observed else 0,
            'files': files if observed else [], 'git_state_verified': False, 'repository_authenticated': False,
            'working_tree': 'unknown', 'head_membership': 'unknown', 'filters': 'unknown', 'untracked': 'unknown',
            'commit_authorized': False, 'mutation_authorized': False, 'recorded_at': index.timestamp()}
    if d['version'] == 2:
        result['object_acquisition'] = objects.store.provenance() if observed else None
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
        payload = json.dumps(result, ensure_ascii=False, separators=(',', ':'))
        if len(payload.encode('utf-8')) > RESPONSE_LIMIT:
            raise ValueError()
        print(payload)
        return 0 if result['status'] == 'observed' else 2
    except (OSError, ValueError, TypeError, UnicodeError, RecursionError):
        print('Declared-object read unavailable.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
