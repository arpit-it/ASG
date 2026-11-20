# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Observe bounded project metadata, without commands or source verification.

Raw manifest bytes are base64 transport, not validated YAML. Descriptor anchoring
is not an atomic repository snapshot or an OS sandbox. Callers need a process
deadline for unavailable or hostile filesystems. Main existence checks require an openable single-link regular file but do not
read its body. This helper is not app-integrated.
"""
import base64
import errno
import json
import os
import stat
import sys

MANIFEST_LIMIT = 64 * 1024
OUTPUT_LIMIT = 128 * 1024
RUNNERS = ('android', 'ios', 'web', 'macos', 'windows', 'linux')
SUPPORTED_HOST = (os.name == 'posix' and all(getattr(os, n, 0) for n in
                  ('O_DIRECTORY', 'O_NOFOLLOW', 'O_NONBLOCK')) and
                  os.open in os.supports_dir_fd and os.stat in os.supports_dir_fd and
                  os.stat in os.supports_follow_symlinks)


class Refusal(Exception):
    def __init__(self, status, reason):
        self.status, self.reason = status, reason


def report(status, reason=None, **values):
    return {'version': 1, 'scope': 'project-metadata-files', 'status': status,
            'reason': reason, 'manifest_base64': None, 'included_runners': [],
            'main_present': None, 'source_verified': False, **values}


def signature(value):
    return (value.st_dev, value.st_ino, value.st_mode, value.st_nlink,
            value.st_size, value.st_mtime_ns, value.st_ctime_ns)


class Reader:
    def __init__(self):
        self.fds, self.directories, self.files, self.missing = [], [], [], []
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

    def regular(self, parent, name, limit=None):
        try:
            before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            self.missing.append((parent, name))
            raise
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise Refusal('unsupported', 'unsafe_metadata')
        if limit is not None and before.st_size > limit:
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
        if limit is None:
            self.files.append((parent, name, fd, signature(before)))
            return None  # Main entry existence only; never read its content.
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
        except OSError:
            raise Refusal('changed', 'metadata_changed') from None

    def close(self):
        for fd in reversed(self.fds):
            try:
                os.close(fd)
            except OSError:
                pass


def inspect_project(root):
    if not SUPPORTED_HOST:
        return report('unsupported', 'posix_nofollow_unavailable')
    reader = Reader()
    try:
        selected = reader.root(root)
        try:
            manifest = reader.regular(selected, 'pubspec.yaml', MANIFEST_LIMIT)
        except FileNotFoundError:
            raise Refusal('invalid', 'manifest_missing') from None
        try:
            lib = reader.directory(selected, 'lib')
            reader.regular(lib, 'main.dart')
        except FileNotFoundError:
            raise Refusal('invalid', 'source_entry_missing') from None
        runners = []
        for name in RUNNERS:
            try:
                reader.directory(selected, name)
            except FileNotFoundError:
                continue
            runners.append(name)
        reader.validate()
        return report('observed', manifest_base64=base64.b64encode(manifest).decode('ascii'),
                      included_runners=runners, main_present=True)
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
    result = json.dumps(inspect_project(args[1]), sort_keys=True, separators=(',', ':'))
    if len(result.encode('utf-8')) > OUTPUT_LIMIT:
        print(json.dumps(report('unavailable', 'output_limit'), sort_keys=True))
        return 2
    print(result)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
