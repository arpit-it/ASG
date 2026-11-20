# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Observe contained loose .git file declarations; never run Git or certify state.

POSIX no-follow descriptors bound path access. This is neither an OS sandbox nor
an atomic repository snapshot. Callers must impose a process deadline for hostile
or unavailable filesystems. Config, index, objects and packed refs are not read.
"""
import errno
import json
import os
import re
import stat
import sys

HEAD_LIMIT = 4096
REF_LIMIT = 256
MARKERS = ('commondir', 'gitdir', 'reftable', 'packed-refs')
SUPPORTED_HOST = (os.name == 'posix' and all(getattr(os, n, 0) for n in
                  ('O_DIRECTORY', 'O_NOFOLLOW', 'O_NONBLOCK')) and
                  os.open in os.supports_dir_fd and os.stat in os.supports_dir_fd and
                  os.stat in os.supports_follow_symlinks)
OID = re.compile(r'(?:[0-9a-f]{40}|[0-9a-f]{64})', re.ASCII)


class Refusal(Exception):
    def __init__(self, status, reason):
        self.status, self.reason = status, reason


def report(status, reason=None, **values):
    return {'version': 1, 'layout': 'direct-dotgit-files',
            'scope': 'literal-file-declarations', 'status': status,
            'head_form': None, 'declared_ref': None, 'declared_oid': None,
            'oid_source': None, 'reason': reason, 'git_state_verified': False,
            'working_tree': 'unknown', 'ahead_behind': 'unknown',
            'conflict': 'unknown', **values}


def signature(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)


class Reader:
    def __init__(self):
        self.fds, self.directories, self.files, self.missing = [], [], [], []
        self.git = None
        self.directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        self.file_flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
        self.directory_flags |= getattr(os, 'O_CLOEXEC', 0)
        self.file_flags |= getattr(os, 'O_CLOEXEC', 0)

    def directory(self, parent, name):
        try:
            fd = os.open(name, self.directory_flags, dir_fd=parent)
        except FileNotFoundError:
            self.missing.append((parent, name))
            raise
        except OSError as error:
            if error.errno in (errno.ELOOP, errno.ENOTDIR):
                raise Refusal('unsupported', 'directory_indirection') from None
            raise
        self.fds.append(fd)
        self.directories.append((parent, name, fd))
        return fd

    def root(self, path):
        if (not isinstance(path, str) or not os.path.isabs(path) or path == '/' or
                os.path.normpath(path) != path or len(path.encode('utf-8')) > 4096 or
                any(ord(c) < 32 or ord(c) == 127 for c in path)):
            raise Refusal('unavailable', 'invalid_root')
        parts = path.split('/')[1:]
        if len(parts) > 128 or any(p in ('', '.', '..') for p in parts):
            raise Refusal('unsupported', 'root_path_subset')
        fd = os.open('/', self.directory_flags)
        self.fds.append(fd)
        for part in parts:
            fd = self.directory(fd, part)
        return fd

    def layout(self, changed=False):
        for name in MARKERS:
            try:
                os.stat(name, dir_fd=self.git, follow_symlinks=False)
            except FileNotFoundError:
                continue
            raise Refusal('changed' if changed else 'unsupported',
                          'layout_changed' if changed else name.replace('-', '_') + '_present')

    def read(self, parent, name, limit):
        try:
            before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            self.missing.append((parent, name))
            raise
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise Refusal('unsupported', 'unsafe_metadata')
        if before.st_size > limit:
            raise Refusal('invalid', 'metadata_too_large')
        try:
            fd = os.open(name, self.file_flags, dir_fd=parent)
        except OSError as error:
            if error.errno in (errno.ENOENT, errno.ELOOP, errno.ENOTDIR):
                raise Refusal('changed', 'metadata_changed') from None
            raise
        self.fds.append(fd)
        opened = os.fstat(fd)
        if signature(before) != signature(opened):
            raise Refusal('changed', 'metadata_changed')
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(4096, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > limit:
            raise Refusal('changed', 'metadata_changed')
        if len(data) != before.st_size or signature(os.fstat(fd)) != signature(before):
            raise Refusal('changed', 'metadata_changed')
        self.files.append((parent, name, fd, signature(before)))
        return bytes(data)

    def validate(self):
        try:
            for parent, name, fd in self.directories:
                current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                held = os.fstat(fd)
                if (not stat.S_ISDIR(current.st_mode) or
                        (current.st_dev, current.st_ino) != (held.st_dev, held.st_ino)):
                    raise Refusal('changed', 'directory_changed')
            for parent, name, fd, expected in self.files:
                current = os.stat(name, dir_fd=parent, follow_symlinks=False)
                if signature(current) != expected or signature(os.fstat(fd)) != expected:
                    raise Refusal('changed', 'metadata_changed')
            for parent, name in self.missing:
                try:
                    os.stat(name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                raise Refusal('changed', 'missing_metadata_appeared')
            if self.git is not None:
                self.layout(changed=True)
        except OSError:
            raise Refusal('changed', 'metadata_changed') from None

    def close(self):
        for fd in reversed(self.fds):
            try:
                os.close(fd)
            except OSError:
                pass


def line(data, reason):
    try:
        value = data.decode('ascii')
    except UnicodeError:
        raise Refusal('invalid', reason) from None
    if value.endswith('\n'):
        value = value[:-1]
    if not value or any(c in value for c in '\r\n\0'):
        raise Refusal('invalid', reason)
    return value


def oid(value):
    return OID.fullmatch(value) is not None and any(c != '0' for c in value)


def reference(value):
    if not value.startswith('refs/heads/') or len(value) > 256:
        return False
    parts = value.split('/')
    return (len(parts) <= 16 and '..' not in value and '@{' not in value and
            not any(ord(c) <= 32 or ord(c) >= 127 or c in '~^:?*[]\\' for c in value) and
            all(p and not p.startswith('.') and not p.endswith(('.', '.lock')) for p in parts))


def inspect_head(path):
    if not SUPPORTED_HOST:
        return report('unsupported', 'posix_nofollow_unavailable')
    reader = Reader()
    try:
        root = reader.root(path)
        try:
            reader.git = reader.directory(root, '.git')
        except FileNotFoundError:
            reader.validate()
            return report('not_present', 'no_direct_git_directory')
        reader.layout()
        try:
            head = line(reader.read(reader.git, 'HEAD', HEAD_LIMIT), 'invalid_head')
        except FileNotFoundError:
            raise Refusal('invalid', 'head_missing') from None
        if head.startswith('ref: '):
            ref = head[5:]
            if not reference(ref):
                raise Refusal('invalid', 'invalid_ref')
            try:
                parent = reader.git
                parts = ref.split('/')
                for part in parts[:-1]:
                    parent = reader.directory(parent, part)
                target = line(reader.read(parent, parts[-1], REF_LIMIT), 'invalid_ref')
            except FileNotFoundError:
                reader.validate()
                return report('unresolved', 'loose_ref_missing',
                              head_form='symbolic', declared_ref=ref)
            if not oid(target):
                raise Refusal('invalid', 'invalid_ref')
            result = report('observed', head_form='symbolic', declared_ref=ref,
                            declared_oid=target, oid_source='loose_ref')
        elif oid(head):
            result = report('observed', head_form='direct_oid', declared_oid=head,
                            oid_source='head')
        else:
            raise Refusal('invalid', 'invalid_head')
        reader.validate()
        return result
    except Refusal as error:
        return report(error.status, error.reason)
    except NotImplementedError:
        return report('unsupported', 'posix_nofollow_unavailable')
    except (OSError, ValueError, UnicodeError):
        return report('unavailable', 'read_unavailable')
    finally:
        reader.close()


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 2 or args[0] != '--root':
        print(json.dumps(report('unavailable', 'invalid_request'), sort_keys=True))
        return 2
    print(json.dumps(inspect_head(args[1]), sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
