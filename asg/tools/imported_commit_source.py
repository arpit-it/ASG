# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Observe bounded selected source blobs from an immutable Git commit.

Standalone prerequisite; not integrated into app consent or native job ownership.
Object identities describe supplied immutable bytes, never working-tree state,
current approval, an authenticated repository or permission to write/execute.
"""
import base64
import hashlib
import posixpath
import re
import json
import os
import selectors
import signal
import stat
import subprocess
import sys
import time
from dataclasses import dataclass

COMMIT_LIMIT = 64 * 1024
TREE_LIMIT = 1024 * 1024
FILE_LIMIT = 32 * 1024
MAX_TREE_ENTRIES = 4096
_OID = re.compile(r'[0-9a-f]{40}', re.ASCII)
_COMPONENT = re.compile(rb'[A-Za-z0-9_. @-]{1,100}')
_SELECTED_COMPONENT = re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', re.ASCII)


class InvalidCommitSource(ValueError):
    """Private, fixed validation failure; never echo supplied source content."""

    def __init__(self):
        super().__init__('Invalid or oversized immutable source inputs.')


def valid_oid(value):
    return (isinstance(value, str) and _OID.fullmatch(value) is not None
            and value != '0' * 40)


def selection(paths):
    if not isinstance(paths, (list, tuple)) or not 1 <= len(paths) <= 4:
        raise InvalidCommitSource()
    result = tuple(paths)
    for value in result:
        if (not isinstance(value, str) or not 1 <= len(value) <= 512
                or not value.isascii() or '\\' in value):
            raise InvalidCommitSource()
        parts = value.split('/')
        if (not 2 <= len(parts) <= 16 or parts[0] not in ('lib', 'test')
                or not parts[-1].endswith('.dart')
                or any(p in ('.', '..') or _SELECTED_COMPONENT.fullmatch(p) is None
                       for p in parts)):
            raise InvalidCommitSource()
    if len({value.casefold() for value in result}) != len(result):
        raise InvalidCommitSource()
    return result


@dataclass(frozen=True)
class CommitSourceRequest:
    root: str
    commit: str
    paths: tuple


def request(root, commit, paths):
    try:
        if (not isinstance(root, str) or not posixpath.isabs(root)
                or root == '/' or root.startswith('//')
                or posixpath.normpath(root) != root
                or len(root.encode('utf-8', errors='strict')) > 4096
                or len(root.split('/')[1:]) > 128
                or any(ord(c) < 32 or ord(c) == 127 for c in root)
                or not valid_oid(commit)):
            raise InvalidCommitSource()
        return CommitSourceRequest(root, commit, selection(paths))
    except (UnicodeError, TypeError):
        raise InvalidCommitSource() from None


def verified_object(kind, oid, data):
    limits = {'commit': COMMIT_LIMIT, 'tree': TREE_LIMIT, 'blob': FILE_LIMIT}
    if (not isinstance(kind, str) or kind not in limits or not valid_oid(oid) or not isinstance(data, bytes)
            or len(data) > limits[kind]):
        raise InvalidCommitSource()
    header = kind.encode('ascii') + b' ' + str(len(data)).encode('ascii') + b'\0'
    if hashlib.sha1(header + data).hexdigest() != oid:
        raise InvalidCommitSource()
    return data


def commit_tree(oid, data):
    data = verified_object('commit', oid, data)
    headers, separator, _ = data.partition(b'\n\n')
    first, *rest = headers.split(b'\n')
    if not separator or not first.startswith(b'tree '):
        raise InvalidCommitSource()
    try:
        tree = first[5:].decode('ascii')
    except UnicodeError:
        raise InvalidCommitSource() from None
    if not valid_oid(tree) or any(line.startswith(b'tree ') for line in rest):
        raise InvalidCommitSource()
    return tree


@dataclass(frozen=True)
class TreeEntry:
    mode: str
    name: str
    oid: str


def tree_entries(oid, data):
    data = verified_object('tree', oid, data)
    entries, seen, previous, offset = [], set(), None, 0
    while offset < len(data):
        space = data.find(b' ', offset)
        end = data.find(b'\0', space + 1)
        if space < 0 or end < 0 or end + 21 > len(data):
            raise InvalidCommitSource()
        mode, name = data[offset:space], data[space + 1:end]
        child = data[end + 1:end + 21].hex()
        if (mode not in (b'40000', b'100644', b'100755')
                or _COMPONENT.fullmatch(name) is None
                or name.lower() in (b'.', b'..', b'.git')
                or name.lower() in seen or not valid_oid(child)):
            raise InvalidCommitSource()
        order = name + (b'/' if mode == b'40000' else b'')
        if previous is not None and order <= previous:
            raise InvalidCommitSource()
        seen.add(name.lower())
        previous = order
        entries.append(TreeEntry(mode.decode('ascii'), name.decode('ascii'), child))
        if len(entries) > MAX_TREE_ENTRIES:
            raise InvalidCommitSource()
        offset = end + 21
    return tuple(entries)


def blob_record(path, oid, data):
    selection([path])
    data = verified_object('blob', oid, data)
    try:
        text = data.decode('utf-8', errors='strict')
    except UnicodeError:
        raise InvalidCommitSource() from None
    if '\0' in text:
        raise InvalidCommitSource()
    return {'path': path, 'git_blob': oid, 'byte_length': len(data),
            'sha256': hashlib.sha256(data).hexdigest(),
            'content_base64': base64.b64encode(data).decode('ascii')}

# Native object reads are separate from the supplied-byte parsers.
AGGREGATE_LIMIT = 64 * 1024
OUTPUT_LIMIT = 128 * 1024
MAX_FILES = 2048
MAX_DIRECTORIES = 128
DEADLINE_SECONDS = 10
_stop_requested = False


class _Refused(Exception):
    def __init__(self, reason):
        self.reason = reason


def _stop(_signum, _frame):
    global _stop_requested
    _stop_requested = True


def _signature(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)


class _Repository:
    """Direct standard .git layout only; cooperative checks, not an OS sandbox."""
    def __init__(self, selected):
        self.selected, self.fds, self.directories = selected, [], []
        self.layout = None

    def directory(self, parent, name):
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        self.fds.append(fd)
        self.directories.append((parent, name, fd))
        return fd

    def open(self):
        if (os.name != 'posix' or any(not getattr(os, n, 0) for n in ('O_DIRECTORY', 'O_NOFOLLOW', 'O_NONBLOCK'))
                or os.open not in os.supports_dir_fd):
            raise _Refused('unsupported_host')
        parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        self.fds.append(parent)
        for part in self.selected.root.split('/')[1:]:
            parent = self.directory(parent, part)
        self.root = parent
        self.git = self.directory(parent, '.git')
        self.objects = self.directory(self.git, 'objects')
        self.validate()

    def optional(self, parent, name):
        try:
            return os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            return None

    def regular(self, parent, name):
        value = self.optional(parent, name)
        if value is not None and (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1):
            raise _Refused('unsupported_layout')
        return value

    def config(self):
        before = self.regular(self.git, 'config')
        if before is None or before.st_size > 16384:
            raise _Refused('unsupported_configuration')
        fd = os.open('config', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=self.git)
        try:
            data = os.read(fd, 16385)
            if (_signature(os.fstat(fd)) != _signature(before)
                    or _signature(os.stat('config', dir_fd=self.git, follow_symlinks=False)) != _signature(before)):
                raise _Refused('repository_changed')
        finally:
            os.close(fd)
        # Small explicit subset: includes, extensions, worktree overrides, filters,
        # external helpers, alternate config syntax and line continuations refuse.
        allowed = {'core': {'repositoryformatversion', 'filemode', 'bare',
                            'logallrefupdates', 'ignorecase', 'precomposeunicode'},
                   'user': {'name', 'email'}, 'remote': {'url', 'fetch', 'pushurl', 'tagopt'},
                   'branch': {'remote', 'merge'}}
        section, seen = None, set()
        try:
            text = data.decode('utf-8', errors='strict')
            if len(data) != before.st_size or '\\' in text or '\0' in text:
                raise _Refused('unsupported_configuration')
            for raw in text.splitlines():
                line = raw.strip()
                if not line or line.startswith(('#', ';')):
                    continue
                header = re.fullmatch(
                    r'\[(core|user|remote|branch)(?: "[^"\r\n]{1,256}")?\]',
                    line, re.ASCII | re.IGNORECASE)
                if header:
                    section = header[1].lower()
                    continue
                setting = re.fullmatch(r'([A-Za-z][A-Za-z0-9]*)\s*=\s*(.*)', line)
                if setting is None or section is None or setting[1].lower() not in allowed[section]:
                    raise _Refused('unsupported_configuration')
                key, value = setting[1].lower(), setting[2].strip().lower()
                if section == 'core':
                    expected = {'repositoryformatversion': {'0'}, 'bare': {'false'}}.get(key, {'true', 'false'})
                    if key in seen or value not in expected:
                        raise _Refused('unsupported_configuration')
                    seen.add(key)
            if not {'repositoryformatversion', 'bare'} <= seen:
                raise _Refused('unsupported_configuration')
        except UnicodeError:
            raise _Refused('unsupported_configuration') from None
        return _signature(before)

    def validate(self, oid=None):
        for parent, name, fd in self.directories:
            current = os.stat(name, dir_fd=parent, follow_symlinks=False)
            held = os.fstat(fd)
            if not stat.S_ISDIR(current.st_mode) or (current.st_dev, current.st_ino) != (held.st_dev, held.st_ino):
                raise _Refused('repository_changed')
        for marker in ('commondir', 'gitdir', 'config.worktree', 'shallow'):
            if self.optional(self.git, marker) is not None:
                raise _Refused('unsupported_layout')
        head = self.regular(self.git, 'HEAD')
        if head is None or head.st_size > 4096:
            raise _Refused('unsupported_layout')
        layout = [('config', self.config()), ('HEAD', _signature(head))]
        for directory in ('info', 'pack'):
            value = self.optional(self.objects, directory)
            if value is None:
                layout.append((directory, None)); continue
            if not stat.S_ISDIR(value.st_mode):
                raise _Refused('unsupported_layout')
            fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.objects)
            try:
                held = os.fstat(fd)
                if (held.st_dev, held.st_ino) != (value.st_dev, value.st_ino):
                    raise _Refused('repository_changed')
                layout.append((directory, (value.st_dev, value.st_ino)))
                if directory == 'info':
                    with os.scandir(fd) as entries:
                        for index, entry in enumerate(entries):
                            if index >= 16 or entry.name not in ('packs', 'commit-graph'):
                                raise _Refused('unsupported_layout')
                            info = self.regular(fd, entry.name)
                            if info is None or info.st_size > 4 * 1024 * 1024:
                                raise _Refused('unsupported_layout')
                            layout.append((entry.name, _signature(info)))
                else:
                    names = []
                    with os.scandir(fd) as entries:
                        for entry in entries:
                            names.append(entry.name)
                            if len(names) > 128:
                                raise _Refused('unsupported_layout')
                    for name in sorted(names):
                        if re.fullmatch(r'pack-[a-f0-9]{40}\.(pack|idx|rev|bitmap|keep|mtimes)', name) is None:
                            raise _Refused('unsupported_layout')
                        info = self.regular(fd, name)
                        if info is None:
                            raise _Refused('repository_changed')
                        layout.append((name, _signature(info)))
            finally:
                os.close(fd)
        layout = tuple(sorted(layout, key=lambda item: item[0]))
        if self.layout is None:
            self.layout = layout
        elif layout != self.layout:
            raise _Refused('repository_changed')
        if oid is not None:
            prefix = self.optional(self.objects, oid[:2])
            if prefix is not None:
                if not stat.S_ISDIR(prefix.st_mode):
                    raise _Refused('unsupported_layout')
                fd = os.open(oid[:2], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.objects)
                try:
                    held = os.fstat(fd)
                    if (held.st_dev, held.st_ino) != (prefix.st_dev, prefix.st_ino):
                        raise _Refused('repository_changed')
                    self.regular(fd, oid[2:])
                finally:
                    os.close(fd)

    def close(self):
        for fd in reversed(self.fds):
            os.close(fd)
        self.fds.clear()


class _ObjectReader:
    def __init__(self, repository, deadline, stopped):
        self.repository, self.deadline, self.stopped = repository, deadline, stopped

    def check(self):
        if self.stopped():
            raise _Refused('stopped')
        if time.monotonic() >= self.deadline:
            raise _Refused('deadline')

    def command(self, args, limit, oid):
        self.check()
        self.repository.validate(oid)
        env = {'PATH': '/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM': '1',
               'GIT_CONFIG_SYSTEM': os.devnull, 'GIT_CONFIG_GLOBAL': os.devnull,
               'GIT_TERMINAL_PROMPT': '0', 'GIT_NO_LAZY_FETCH': '1',
               'GIT_OPTIONAL_LOCKS': '0', 'GIT_ATTR_NOSYSTEM': '1',
               'GIT_GRAFT_FILE': os.devnull}
        root = self.repository.selected.root
        process = subprocess.Popen(['/usr/bin/git', '--no-replace-objects',
                                    '--git-dir=' + root + '/.git',
                                    '--work-tree=' + root,
                                    '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
                                    '-c', 'protocol.allow=never', *args],
                                   cwd='/', env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            data = bytearray()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    self.check()
                    if not selector.select(min(0.05, max(0, self.deadline-time.monotonic()))):
                        continue
                    chunk = os.read(process.stdout.fileno(), min(65536, limit+1-len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                    if len(data) > limit:
                        raise _Refused('object_limit')
            while process.poll() is None:
                self.check()
                time.sleep(0.005)
            if process.returncode:
                raise _Refused('object_unavailable')
            self.check()
            self.repository.validate(oid)
            return bytes(data)
        finally:
            try:
                if process.poll() is None:
                    process.kill()
                process.wait(timeout=1)
            except (OSError, subprocess.TimeoutExpired):
                raise _Refused('cleanup_uncertain') from None
            finally:
                process.stdout.close()

    def read(self, kind, oid):
        limit = {'commit': COMMIT_LIMIT, 'tree': TREE_LIMIT, 'blob': FILE_LIMIT}[kind]
        raw = self.command(['cat-file', '-s', oid], 32, oid)
        if re.fullmatch(rb'[0-9]{1,10}\n', raw) is None or int(raw) > limit:
            raise _Refused('object_limit')
        data = self.command(['cat-file', kind, oid], int(raw), oid)
        return verified_object(kind, oid, data)


def observe(root, commit, paths, *, stopped=None, deadline_seconds=DEADLINE_SECONDS):
    selected, repository = None, None
    try:
        selected = request(root, commit, paths)
        if not isinstance(deadline_seconds, (int, float)) or not 0 < deadline_seconds <= DEADLINE_SECONDS:
            raise InvalidCommitSource()
        deadline = time.monotonic()+deadline_seconds
        repository = _Repository(selected)
        repository.open()
        reader = _ObjectReader(repository, deadline,
                               stopped or (lambda: _stop_requested))
        reader.check()
        tree = commit_tree(commit, reader.read('commit', commit))
        manifest, metadata_bytes, directories = [], 0, 0

        def visit(tree_oid, prefix, depth):
            nonlocal metadata_bytes, directories
            reader.check()
            directories += 1
            if depth > 16 or directories > MAX_DIRECTORIES:
                raise _Refused('tree_limit')
            data = reader.read('tree', tree_oid)
            metadata_bytes += len(data)
            if metadata_bytes > TREE_LIMIT:
                raise _Refused('tree_limit')
            for entry in tree_entries(tree_oid, data):
                name = prefix + entry.name
                if len(name.encode('ascii')) > 512:
                    raise _Refused('tree_limit')
                if entry.mode == '40000':
                    visit(entry.oid, name+'/', depth+1)
                else:
                    manifest.append({'path': name, 'mode': entry.mode, 'git_blob': entry.oid})
                    if len(manifest) > MAX_FILES:
                        raise _Refused('tree_limit')
        visit(tree, '', 1)
        manifest.sort(key=lambda item: item['path'])
        lookup = {item['path']: item for item in manifest}
        files, total = [], 0
        for name in selected.paths:
            if name not in lookup:
                raise _Refused('selected_path_missing')
            entry = lookup[name]
            data = reader.read('blob', entry['git_blob'])
            total += len(data)
            if total > AGGREGATE_LIMIT:
                raise _Refused('sources_limit')
            files.append({**blob_record(name, entry['git_blob'], data), 'mode': entry['mode']})
        reader.check()
        repository.validate()
        reader.check()
        value = _report(selected, 'observed', None)
        manifest_bytes = json.dumps(
            manifest, sort_keys=True, separators=(',', ':')).encode('ascii')
        value.update(tree=tree,
                     manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest(),
                     manifest_files=len(manifest), files=files)
        if len(json.dumps(value, separators=(',', ':')).encode('utf-8')) > OUTPUT_LIMIT:
            raise _Refused('response_limit')
        return value
    except InvalidCommitSource:
        return _report(selected, 'refused', 'invalid_object_or_request')
    except _Refused as error:
        return _report(selected, 'refused', error.reason)
    except (OSError, ValueError, NotImplementedError):
        return _report(selected, 'refused', 'repository_unavailable')
    finally:
        if repository is not None:
            repository.close()


def _report(selected, status, reason):
    return {'version': 1, 'scope': 'imported-commit-source', 'status': status,
            'reason': reason, 'root': selected.root if selected else None,
            'commit': selected.commit if selected else None,
            'selected_paths': list(selected.paths) if selected else [],
            'tree': None, 'manifest_sha256': None, 'manifest_files': None,
            'source_verified': False, 'working_tree': 'unknown',
            'conflict': 'unknown', 'files': []}


def main(argv):
    global _stop_requested
    _stop_requested = False
    for name in ('SIGTERM', 'SIGINT'):
        signal.signal(getattr(signal, name), _stop)
    if (len(argv) not in (6, 8, 10, 12) or argv[0] != '--root'
            or argv[2] != '--commit' or any(argv[i] != '--file' for i in range(4, len(argv), 2))):
        result = _report(None, 'refused', 'invalid_request')
    else:
        result = observe(argv[1], argv[3], argv[5::2])
    if _stop_requested:
        result = _report(None, 'refused', 'stopped')
    payload = (json.dumps(result, separators=(',', ':'))+'\n').encode('utf-8')
    if len(payload) > OUTPUT_LIMIT:
        result = _report(None, 'refused', 'response_limit')
        payload = (json.dumps(result, separators=(',', ':'))+'\n').encode('utf-8')
    sys.stdout.buffer.write(payload)
    return 0 if result['status'] == 'observed' else 2


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
