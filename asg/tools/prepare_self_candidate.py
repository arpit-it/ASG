# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Prepare a private source snapshot from a trusted local ASG repository."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import selectors
import subprocess
import sys
import tempfile
import time

MAX_FILES = 2048
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 24 * 1024 * 1024
MAX_TREE_BYTES = 1024 * 1024
OBJECT_ID = re.compile(rb'[0-9a-f]{40}')
COMPONENT = re.compile(rb'[A-Za-z0-9_. @-]{1,100}')


def read_git(source, args, limit, deadline):
    env = {
        'PATH': '/usr/bin:/bin',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': os.devnull,
        'GIT_NO_LAZY_FETCH': '1',
        'GIT_TERMINAL_PROMPT': '0',
    }
    with subprocess.Popen(
        ['/usr/bin/git', '--no-replace-objects', '-C', str(source), *args],
        env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    ) as process:
        try:
            result = bytearray()
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    if not selector.select(max(0, deadline - time.monotonic())):
                        raise ValueError('Git read timed out.')
                    chunk = os.read(process.stdout.fileno(), min(65536, limit + 1 - len(result)))
                    if not chunk:
                        break
                    result.extend(chunk)
                    if len(result) > limit or time.monotonic() >= deadline:
                        raise ValueError('Git read exceeded its limits.')
            if process.wait(timeout=max(0, deadline - time.monotonic())):
                raise ValueError('Git could not read the requested object.')
            return bytes(result)
        finally:
            if process.poll() is None:
                process.kill()


def parse_tree(raw):
    if not raw.endswith(b'\0'):
        raise ValueError('Expected a nonempty Git tree.')
    records = raw[:-1].split(b'\0')
    if len(records) > MAX_FILES:
        raise ValueError('Candidate contains too many files.')
    entries, prefixes = [], {}
    total = 0
    for record in records:
        metadata, name = record.split(b'\t', 1)
        mode, kind, oid, length = metadata.split()
        parts = name.split(b'/')
        if (kind != b'blob' or mode not in (b'100644', b'100755')
                or not OBJECT_ID.fullmatch(oid) or len(parts) > 16
                or any(not COMPONENT.fullmatch(part)
                       or part.lower() in (b'.', b'..', b'.git') for part in parts)):
            raise ValueError('Unsupported source entry.')
        for index in range(1, len(parts) + 1):
            prefix = b'/'.join(parts[:index])
            leaf = index == len(parts)
            previous = prefixes.get(prefix.lower())
            if previous is not None and (previous != (prefix, leaf) or leaf):
                raise ValueError('Conflicting source paths.')
            prefixes[prefix.lower()] = prefix, leaf
        size = int(length)
        total += size
        if not 0 <= size <= MAX_FILE_BYTES or total > MAX_TOTAL_BYTES:
            raise ValueError('Candidate source exceeds size limits.')
        entries.append(([part.decode('ascii') for part in parts], mode, oid, size))
    return entries


def write_blob(root_fd, parts, mode, data):
    parent = os.dup(root_fd)
    try:
        for part in parts[:-1]:
            try:
                os.mkdir(part, 0o700, dir_fd=parent)
            except FileExistsError:
                pass
            child = os.open(part, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        with os.fdopen(os.open(parts[-1], flags, mode, dir_fd=parent), 'wb') as output:
            output.write(data)
    finally:
        os.close(parent)


def prepare(source, commit, parent):
    """Return a complete candidate path. Only the returned path is ready."""
    if not OBJECT_ID.fullmatch(commit.encode('ascii')):
        raise ValueError('Use the full 40-character commit ID.')
    source = source.resolve(strict=True)
    parent = parent.resolve(strict=True)
    if source == parent or source in parent.parents:
        raise ValueError('Choose a candidate parent outside the source repository.')
    deadline = time.monotonic() + 60
    if read_git(source, ['rev-parse', '--show-toplevel'], 4096, deadline).rstrip(b'\n') != os.fsencode(source):
        raise ValueError('Choose the root of the trusted local repository.')
    if read_git(source, ['cat-file', '-t', commit], 16, deadline) != b'commit\n':
        raise ValueError('The selected object must be a commit.')
    entries = parse_tree(read_git(source, ['ls-tree', '-rlz', commit], MAX_TREE_BYTES, deadline))
    candidate = Path(tempfile.mkdtemp(prefix='asg-self-candidate-', dir=parent))
    try:
        root_fd = os.open(candidate, os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            for parts, mode, oid, size in entries:
                data = read_git(source, ['cat-file', 'blob', oid.decode()], size, deadline)
                digest = hashlib.sha1(b'blob ' + str(size).encode() + b'\0' + data).hexdigest()
                if len(data) != size or digest.encode() != oid:
                    raise ValueError('Source object bytes differ from the selected tree.')
                write_blob(root_fd, parts, 0o700 if mode == b'100755' else 0o600, data)
        finally:
            os.close(root_fd)
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        raise ValueError(f'Preparation stopped. Incomplete files retained at {candidate}.') from error
    return candidate


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path, help='root of the trusted local ASG repository')
    parser.add_argument('commit', help='full reviewed commit ID')
    parser.add_argument('parent', type=Path, help='trusted destination parent outside the repository')
    args = parser.parse_args(argv)
    try:
        candidate = prepare(args.source, args.commit, args.parent)
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        print(f'Candidate unavailable. {error}', file=sys.stderr)
        return 1
    print(candidate)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
