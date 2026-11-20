# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Observe explicitly selected root documents; text never grants authority.

Exact bytes and hashes are bounded observations, not authenticated source or an
atomic repository snapshot. The eventual caller must own a deadline and cleanup.
This standalone helper is not app integrated and makes no model requests.
"""
import base64
import errno
import hashlib
import json
import os
import stat
import sys

DOCUMENT_LIMIT = 32 * 1024
AGGREGATE_LIMIT = 64 * 1024
OUTPUT_LIMIT = 128 * 1024
PATHS = ('AGENTS.md', 'README.md')
SUPPORTED_HOST = (os.name == 'posix' and all(getattr(os, n, 0) for n in
                  ('O_DIRECTORY', 'O_NOFOLLOW', 'O_NONBLOCK')) and
                  os.open in os.supports_dir_fd and os.stat in os.supports_dir_fd and
                  os.stat in os.supports_follow_symlinks)


class Refusal(Exception):
    def __init__(self, status, reason):
        self.status, self.reason = status, reason


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

    def regular(self, parent, name, limit):
        try:
            before = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            self.missing.append((parent, name))
            raise
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise Refusal('unsupported', 'unsafe_document')
        if before.st_size > limit:
            raise Refusal('invalid', 'document_too_large')
        try:
            fd = os.open(name, self.file_flags, dir_fd=parent)
        except OSError as error:
            if error.errno in (errno.ENOENT, errno.ELOOP, errno.ENOTDIR):
                raise Refusal('changed', 'document_changed') from None
            raise
        self.fds.append(fd)
        opened = os.fstat(fd)
        if signature(before) != signature(opened):
            raise Refusal('changed', 'document_changed')
        data = bytearray()
        while len(data) <= limit:
            chunk = os.read(fd, min(4096, limit + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        if len(data) > limit:
            raise Refusal('changed', 'document_changed')
        if len(data) != before.st_size or signature(os.fstat(fd)) != signature(before):
            raise Refusal('changed', 'document_changed')
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
                    raise Refusal('changed', 'document_changed')
            for parent, name in self.missing:
                try:
                    os.stat(name, dir_fd=parent, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                raise Refusal('changed', 'missing_document_appeared')
        except OSError:
            raise Refusal('changed', 'document_changed') from None

    def close(self):
        for fd in reversed(self.fds):
            try:
                os.close(fd)
            except OSError:
                pass


def selection(paths):
    return (isinstance(paths, (list, tuple)) and 1 <= len(paths) <= 2 and
            all(isinstance(p, str) and p in PATHS for p in paths) and
            list(paths) == [p for p in PATHS if p in paths])


def report(paths, status, reason=None, documents=None):
    return {'version': 1, 'scope': 'project-instruction-documents',
            'status': status, 'reason': reason, 'selected_paths': list(paths),
            'documents': documents if status == 'observed' else [],
            'source_verified': False}


def inspect_documents(root, paths):
    if not selection(paths):
        return report([], 'unavailable', 'invalid_selection')
    paths = tuple(paths)  # Freeze the validated readset before any filesystem work.
    if not SUPPORTED_HOST:
        return report(paths, 'unsupported', 'posix_nofollow_unavailable')
    reader = Reader()
    try:
        selected = reader.root(root)
        documents, total = [], 0
        for path in paths:
            try:
                data = reader.regular(selected, path, DOCUMENT_LIMIT)
            except FileNotFoundError:
                raise Refusal('invalid', 'document_missing') from None
            total += len(data)
            if total > AGGREGATE_LIMIT:
                raise Refusal('invalid', 'documents_too_large')
            try:
                text = data.decode('utf-8', errors='strict')
            except UnicodeDecodeError:
                raise Refusal('invalid', 'document_encoding') from None
            if '\x00' in text:
                raise Refusal('invalid', 'document_encoding')
            documents.append({'path': path, 'byte_length': len(data),
                              'sha256': hashlib.sha256(data).hexdigest(),
                              'content_base64': base64.b64encode(data).decode('ascii')})
        reader.validate()
        return report(paths, 'observed', documents=documents)
    except Refusal as error:
        return report(paths, error.status, error.reason)
    except NotImplementedError:
        return report(paths, 'unsupported', 'posix_nofollow_unavailable')
    except (OSError, ValueError, TypeError):
        return report(paths, 'unavailable', 'document_unavailable')
    finally:
        reader.close()


def main(argv):
    if (len(argv) not in (4, 6) or argv[0] != '--root' or
            any(argv[i] != '--file' for i in range(2, len(argv), 2))):
        value = report([], 'unavailable', 'invalid_request')
        code = 2
    else:
        value = inspect_documents(argv[1], argv[3::2])
        code = 0 if value['status'] == 'observed' else 2
    payload = (json.dumps(value, separators=(',', ':')) + '\n').encode('utf-8')
    if len(payload) > OUTPUT_LIMIT:
        payload = (json.dumps(report([], 'unavailable', 'output_limit'),
                              separators=(',', ':')) + '\n').encode('utf-8')
        code = 2
    sys.stdout.buffer.write(payload)
    return code


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
