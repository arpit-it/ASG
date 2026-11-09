# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Prepare a private source snapshot from a trusted local ASG repository."""

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import signal
import stat
import subprocess
import sys
import time

MAX_FILES = 2048
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_TOTAL_BYTES = 24 * 1024 * 1024
MAX_TREE_BYTES = 1024 * 1024
OBJECT_ID = re.compile(rb'[0-9a-f]{40}')
COMPONENT = re.compile(rb'[A-Za-z0-9_. @-]{1,100}')


_stop_requested = False


def request_stop(_signum, _frame):
    global _stop_requested
    _stop_requested = True


def check_stop():
    if _stop_requested:
        raise ValueError('Snapshot preparation stopped.')


def read_git(source, args, limit, deadline):
    check_stop()
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
                    check_stop()
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise ValueError('Git read timed out.')
                    if not selector.select(min(0.1, remaining)):
                        continue
                    chunk = os.read(process.stdout.fileno(), min(65536, limit + 1 - len(result)))
                    if not chunk:
                        break
                    result.extend(chunk)
                    if len(result) > limit or time.monotonic() >= deadline:
                        raise ValueError('Git read exceeded its limits.')
            while process.poll() is None:
                check_stop()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError('Git read timed out.')
                time.sleep(min(0.01, remaining))
            if process.returncode:
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
    parent_fd = open_snapshot_destination(
        parent, (source,), 'Choose a candidate parent outside the source repository.',
    )
    run_fd = stage_fd = None
    run = None
    try:
        if read_git(source, ['rev-parse', '--show-toplevel'], 4096, deadline).rstrip(b'\n') != os.fsencode(source):
            raise ValueError('Choose the root of the trusted local repository.')
        if read_git(source, ['cat-file', '-t', commit], 16, deadline) != b'commit\n':
            raise ValueError('The selected object must be a commit.')
        entries = parse_tree(read_git(source, ['ls-tree', '-rlz', commit], MAX_TREE_BYTES, deadline))
        require_directory_identity(parent, parent_fd)
        for _ in range(8):
            name = f'asg-self-candidate-{secrets.token_hex(4)}'
            try:
                os.mkdir(name, 0o700, dir_fd=parent_fd)
            except FileExistsError:
                continue
            run = parent / name
            break
        if run is None:
            raise ValueError('Could not allocate a new candidate run.')
        run_fd = os.open(run.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        staging = run / 'incomplete'
        ready = run / f'source-{commit}'
        os.mkdir(staging.name, 0o700, dir_fd=run_fd)
        stage_fd = os.open(staging.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=run_fd)

        expected_files = {}
        expected_directories = set()
        for parts, mode, oid, size in entries:
            data = read_git(source, ['cat-file', 'blob', oid.decode()], size, deadline)
            digest = hashlib.sha1(b'blob ' + str(size).encode() + b'\0' + data).hexdigest()
            if len(data) != size or digest.encode() != oid:
                raise ValueError('Source object bytes differ from the selected tree.')
            file_mode = 0o700 if mode == b'100755' else 0o600
            expected_files['/'.join(parts)] = (file_mode, hashlib.sha256(data).digest())
            expected_directories.update('/'.join(parts[:i]) for i in range(1, len(parts)))
            write_blob(stage_fd, parts, file_mode, data)

        def verify_entry(relative, data, mode):
            if data is None:
                if relative not in expected_directories:
                    raise ValueError('Staged snapshot has an unexpected directory.')
                expected_directories.remove(relative)
            elif expected_files.pop(relative, None) != (mode, hashlib.sha256(data).digest()):
                raise ValueError('Staged snapshot differs from the selected tree.')

        entry_limit = len(expected_files) + len(expected_directories)
        staged_digest, _ = scan_candidate(
            staging, sink=verify_entry, allow_incomplete=True, deadline=deadline,
            entry_limit=entry_limit,
        )
        if expected_files or expected_directories:
            raise ValueError('Staged snapshot is missing committed entries.')

        check_preparation_deadline(deadline)
        require_directory_identity(parent, parent_fd)
        require_directory_identity(run, run_fd)
        require_directory_identity(staging, stage_fd)
        check_preparation_deadline(deadline)
        exclusive_rename(run_fd, staging.name, ready.name)

        require_directory_identity(ready, stage_fd)
        published_digest, _ = scan_candidate(ready, deadline=deadline, entry_limit=entry_limit)
        if published_digest != staged_digest:
            raise ValueError('Published snapshot differs from the staged tree.')
        require_directory_identity(parent, parent_fd)
        require_directory_identity(run, run_fd)
        require_directory_identity(ready, stage_fd)
        check_preparation_deadline(deadline)
        return ready
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        if run is None:
            raise
        raise ValueError(f'Preparation stopped. Inspect the candidate run at {run}.') from error
    finally:
        for descriptor in (stage_fd, run_fd, parent_fd):
            if descriptor is not None:
                os.close(descriptor)


def open_directory_no_links(directory):
    """Pin every absolute ancestor rather than following a replaced parent."""
    if not directory.is_absolute():
        raise ValueError('Expected an absolute candidate path.')
    parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in directory.parts[1:]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent)
            parent = child
        return os.dup(parent)
    finally:
        os.close(parent)


def require_directory_identity(directory, descriptor):
    current = open_directory_no_links(directory)
    try:
        observed = os.fstat(current)
        owned = os.fstat(descriptor)
        if (observed.st_dev, observed.st_ino) != (owned.st_dev, owned.st_ino):
            raise ValueError('Candidate directory identity changed during preparation.')
    finally:
        os.close(current)


def check_preparation_deadline(deadline):
    check_stop()
    if deadline is not None and time.monotonic() >= deadline:
        raise ValueError('Snapshot verification timed out.')


def scan_candidate(candidate, capture=None, sink=None, allow_incomplete=False, *, deadline=None, entry_limit=None):
    """Hash names, executable bits and bytes without following candidate links."""
    if ((not re.fullmatch(r'source-[0-9a-f]{40}', candidate.name)
             and not (allow_incomplete and candidate.name == 'incomplete'))
            or not candidate.parent.name.startswith('asg-self-candidate-')
            or candidate.resolve(strict=True) != candidate):
        raise ValueError('Choose a prepared candidate directory.')
    digest = hashlib.sha256(b'ASG candidate tree v1\0')
    if entry_limit is None:
        entry_limit = MAX_FILES * 2
    entries = 0
    files = 0
    total = 0
    observed = {}
    index = {}

    def identity(info):
        return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
                info.st_size, info.st_mtime_ns, info.st_ctime_ns)

    def visit(directory, prefix, depth):
        nonlocal entries, files, total
        initial = os.fstat(directory)
        with os.scandir(directory) as children:
            names = []
            for child in children:
                check_preparation_deadline(deadline)
                entries += 1
                if entries > entry_limit:
                    raise ValueError('Candidate has too many entries.')
                names.append(os.fsencode(child.name))
        seen = set()
        for name in sorted(names):
            check_preparation_deadline(deadline)
            folded = name.lower()
            if (depth >= 16 or not COMPONENT.fullmatch(name)
                    or folded in (b'.', b'..', b'.git') or folded in seen):
                raise ValueError('Unsupported candidate path.')
            seen.add(folded)
            relative = prefix + name
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            with_fd = os.open(name, flags, dir_fd=directory)
            try:
                info = os.fstat(with_fd)
                observed[relative] = identity(info)
                if stat.S_ISDIR(info.st_mode):
                    digest.update(b'D' + relative + b'\0')
                    if sink is not None:
                        sink(relative.decode('ascii'), None, None)
                    visit(with_fd, relative + b'/', depth + 1)
                    continue
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError('Expected a regular candidate file.')
                with os.fdopen(os.dup(with_fd), 'rb') as stream:
                    data = stream.read(MAX_FILE_BYTES + 1)
                files += 1
                total += len(data)
                if (files > MAX_FILES or len(data) > MAX_FILE_BYTES or total > MAX_TOTAL_BYTES
                        or len(data) != info.st_size
                        or os.fstat(with_fd).st_mtime_ns != info.st_mtime_ns
                        or os.fstat(with_fd).st_ctime_ns != info.st_ctime_ns):
                    raise ValueError('Candidate changed or exceeds size limits.')
                mode = b'100755' if info.st_mode & stat.S_IXUSR else b'100644'
                oid = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()
                relative_name = relative.decode('ascii')
                index[relative_name] = (mode.decode(), oid)
                if sink is not None:
                    sink(relative_name, data, 0o700 if mode == b'100755' else 0o600)
                if capture is not None and relative_name in capture:
                    capture[relative_name] = data
                executable = b'X' if info.st_mode & stat.S_IXUSR else b'F'
                digest.update(executable + relative + b'\0' + hashlib.sha256(data).digest())
            finally:
                os.close(with_fd)

        current = os.fstat(directory)
        if (initial.st_mtime_ns, initial.st_ctime_ns) != (current.st_mtime_ns, current.st_ctime_ns):
            raise ValueError('Candidate directory changed during review.')

    root = open_directory_no_links(candidate)
    try:
        root_identity = identity(os.fstat(root))
        visit(root, b'', 0)
        for relative, expected in observed.items():
            check_preparation_deadline(deadline)
            parts = relative.split(b'/')
            parent = os.dup(root)
            try:
                for part in parts[:-1]:
                    child = os.open(part, os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                    os.close(parent)
                    parent = child
                current = os.stat(parts[-1], dir_fd=parent, follow_symlinks=False)
                if identity(current) != expected:
                    raise ValueError('Candidate changed during review.')
            finally:
                os.close(parent)
        current_root = open_directory_no_links(candidate)
        try:
            if identity(os.fstat(current_root)) != root_identity:
                raise ValueError('Candidate directory changed during review.')
        finally:
            os.close(current_root)
    finally:
        os.close(root)
    if not files:
        raise ValueError('Candidate directory is empty.')
    return digest.hexdigest(), index


def fingerprint(candidate):
    return scan_candidate(candidate)[0]


def selected_baseline(candidate, source, commit):
    """Read only the explicitly selected repository commit's bounded tree."""
    if not OBJECT_ID.fullmatch(commit.encode('ascii')):
        raise ValueError('Use the full reviewed commit ID.')
    source = source.resolve(strict=True)
    canonical = candidate.resolve(strict=True)
    if source == canonical or canonical in source.parents:
        raise ValueError('Choose a trusted repository outside the candidate.')
    deadline = time.monotonic() + 15
    if read_git(source, ['rev-parse', '--show-toplevel'], 4096, deadline).rstrip(b'\n') != os.fsencode(source):
        raise ValueError('Choose the trusted repository root.')
    if read_git(source, ['cat-file', '-t', commit], 16, deadline) != b'commit\n':
        raise ValueError('The baseline must be an available commit.')
    entries = parse_tree(read_git(source, ['ls-tree', '-rlz', commit], MAX_TREE_BYTES, deadline))
    return source, entries, deadline


def comparison_result(commit, digest, baseline, actual):
    counts = {'added': 0, 'modified': 0, 'removed': 0, 'executableChanged': 0}
    changes = []
    characters = 0
    for name in sorted(baseline.keys() | actual.keys()):
        check_stop()
        before, after = baseline.get(name), actual.get(name)
        if before == after:
            continue
        kind = 'added' if before is None else 'removed' if after is None else 'modified'
        mode_changed = before is not None and after is not None and before[0] != after[0]
        counts[kind] += 1
        counts['executableChanged'] += int(mode_changed)
        if len(changes) < 100 and characters + len(name) <= 16384:
            changes.append({'path': name, 'kind': kind, 'executableChanged': mode_changed})
            characters += len(name)
    return {'schemaVersion': 1, 'commit': commit, 'digest': digest, 'counts': counts,
            'changes': changes, 'truncated': len(changes) < sum(counts[k] for k in ('added', 'modified', 'removed'))}


def compare_candidate(candidate, source, commit):
    """Compare with the selected baseline; a directory name proves no origin."""
    _, entries, _ = selected_baseline(candidate, source, commit)
    baseline = {'/'.join(parts): (mode.decode(), oid.decode()) for parts, mode, oid, _ in entries}
    digest, actual = scan_candidate(candidate)
    return comparison_result(commit, digest, baseline, actual)


REVIEW_BYTES = 16384
REVIEW_LINES = 500


def review_side(data):
    if data is None:
        return {'state': 'absent', 'text': None}
    if len(data) > REVIEW_BYTES:
        return {'state': 'byteLimit', 'text': None}
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return {'state': 'unsupported', 'text': None}
    if any((ord(c) < 32 and c not in '\t\r\n') or 127 <= ord(c) <= 159 for c in text):
        return {'state': 'unsupported', 'text': None}
    if len(text.splitlines()) > REVIEW_LINES:
        return {'state': 'lineLimit', 'text': None}
    return {'state': 'text', 'text': text}


def review_file(candidate, source, commit, expected_digest, name):
    """Return complete bounded text only for a displayed fingerprint-bound change."""
    if (not re.fullmatch(r'[a-f0-9]{64}', expected_digest)
            or len(name.split('/')) > 16
            or any(not COMPONENT.fullmatch(os.fsencode(part))
                   or part.lower() in ('.', '..', '.git') for part in name.split('/'))):
        raise ValueError('Invalid file selection.')
    source, entries, deadline = selected_baseline(candidate, source, commit)
    baseline = {'/'.join(parts): (mode.decode(), oid.decode()) for parts, mode, oid, _ in entries}
    selected = next((entry for entry in entries if '/'.join(entry[0]) == name), None)
    before = None
    before_oversized = False
    if selected is not None:
        _, _, oid, size = selected
        if size > REVIEW_BYTES:
            before_oversized = True
        else:
            before = read_git(source, ['cat-file', 'blob', oid.decode()], size, deadline)
            observed = hashlib.sha1(b'blob ' + str(size).encode() + b'\0' + before).hexdigest()
            if len(before) != size or observed.encode() != oid:
                raise ValueError('Baseline blob changed or is corrupt.')
    capture = {name: None}
    digest, actual = scan_candidate(candidate, capture)
    result = comparison_result(commit, digest, baseline, actual)
    if digest != expected_digest or not any(change['path'] == name for change in result['changes']):
        raise ValueError('Candidate or displayed selection changed. Review again.')
    return {'schemaVersion': 1, 'commit': commit, 'digest': digest, 'path': name,
            'before': {'state': 'byteLimit', 'text': None} if before_oversized else review_side(before),
            'after': review_side(capture[name])}



def proposal_path(name):
    return (isinstance(name, str)
            and re.fullmatch(r'asg/(lib|test)/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*\.dart', name)
            and len(name.split('/')) <= 16)


def proposal_read(candidate, name):
    if not proposal_path(name):
        raise ValueError('Select an existing bounded Dart source file.')
    captured = {name: None}
    digest, _ = scan_candidate(candidate, captured)
    side = review_side(captured[name])
    if side['state'] != 'text':
        raise ValueError('Select complete supported text within the proposal limits.')
    return {'schemaVersion': 1, 'digest': digest, 'path': name,
            'before': side['text'], 'beforeHash': hashlib.sha256(captured[name]).hexdigest()}


def exclusive_rename(directory, source, target):
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        function, flag = library.renameatx_np, 4
    elif sys.platform.startswith('linux') and hasattr(library, 'renameat2'):
        function, flag = library.renameat2, 1
    else:
        raise ValueError('Exclusive publication is unavailable on this host.')
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(directory, os.fsencode(source), directory, os.fsencode(target), flag):
        raise OSError(ctypes.get_errno(), 'Exclusive publication refused.')



def open_snapshot_destination(destination, protected_paths, outside_error):
    """Open a destination outside the protected directory identities."""
    if any(part.lower().endswith('.app') for part in destination.parts):
        raise ValueError('Choose a destination outside application bundles.')
    forbidden = []
    held = []
    try:
        for path in protected_paths:
            if path is None:
                continue
            descriptor = open_directory_no_links(path)
            held.append(descriptor)
            info = os.fstat(descriptor)
            forbidden.append((info.st_dev, info.st_ino))
        parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in destination.parts[1:]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
                os.close(parent)
                parent = child
                info = os.fstat(parent)
                if (info.st_dev, info.st_ino) in forbidden:
                    raise ValueError(outside_error)
            return os.dup(parent)
        finally:
            os.close(parent)
    finally:
        for descriptor in held:
            os.close(descriptor)


def apply_proposal(payload):
    expected = {'snapshot', 'path', 'expectedDigest', 'beforeHash', 'afterHash',
                'replacement', 'destination', 'trustedSource', 'runName'}
    if (not isinstance(payload, dict) or set(payload) != expected
            or not all(isinstance(payload[k], str) for k in expected)):
        raise ValueError('Invalid proposal payload.')
    candidate = Path(payload['snapshot'])
    destination = Path(payload['destination'])
    name = payload['path']
    if (not proposal_path(name)
            or not re.fullmatch(r'asg-self-candidate-[a-f0-9]{8}', payload['runName'])
            or any(not re.fullmatch(r'[a-f0-9]{64}', payload[k])
                   for k in ('expectedDigest', 'beforeHash', 'afterHash'))):
        raise ValueError('Invalid proposal identity.')
    replacement = payload['replacement'].encode('utf-8')
    if (not replacement.strip() or review_side(replacement)['state'] != 'text'
            or hashlib.sha256(replacement).hexdigest() != payload['afterHash']):
        raise ValueError('Invalid replacement text.')
    if destination.resolve(strict=True) != destination:
        raise ValueError('Choose a canonical destination without links.')
    if destination == candidate or candidate in destination.parents:
        raise ValueError('Choose a destination outside the candidate.')
    if payload['trustedSource']:
        trusted = Path(payload['trustedSource']).resolve(strict=True)
        if destination == trusted or trusted in destination.parents:
            raise ValueError('Choose a destination outside the trusted checkout.')
    parent_fd = open_snapshot_destination(
        destination, (candidate, Path(payload['trustedSource']) if payload['trustedSource'] else None),
        'Destination must be outside the candidate and trusted checkout.',
    )
    run_fd = stage_fd = None
    run = None
    total = substitutions = 0
    output_hash = hashlib.sha256(b'ASG candidate tree v1\0')
    try:
        parent_identity = os.fstat(parent_fd)
        run = payload['runName']
        os.mkdir(run, 0o700, dir_fd=parent_fd)
        run_fd = os.open(run, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
        os.mkdir('incomplete', 0o700, dir_fd=run_fd)
        stage_fd = os.open('incomplete', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=run_fd)

        def copy(relative, data, mode):
            nonlocal total, substitutions
            check_stop()
            parts = relative.split('/')
            if data is None:
                output_hash.update(b'D' + relative.encode('ascii') + b'\0')
                holder = os.dup(stage_fd)
                try:
                    for part in parts:
                        try:
                            os.mkdir(part, 0o700, dir_fd=holder)
                        except FileExistsError:
                            pass
                        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=holder)
                        os.close(holder)
                        holder = child
                finally:
                    os.close(holder)
                return
            if relative == name:
                side = review_side(data)
                if (side['state'] != 'text' or hashlib.sha256(data).hexdigest() != payload['beforeHash']
                        or data == replacement):
                    raise ValueError('Original source changed or replacement is a no-op.')
                header = re.match(rb'^(?://[^\n]*\n)+', data)
                if b'SPDX-License-Identifier: MPL-2.0' in data or b'copyright' in data.lower():
                    if (header is None or not (b'SPDX-License-Identifier: MPL-2.0' in header.group(0) or b'copyright' in header.group(0).lower())
                            or not replacement.startswith(header.group(0))):
                        raise ValueError('Preserve the existing legal header.')
                data = replacement
                substitutions += 1
            total += len(data)
            if total > MAX_TOTAL_BYTES:
                raise ValueError('Result exceeds candidate size limits.')
            output_hash.update((b'X' if mode & stat.S_IXUSR else b'F') + relative.encode('ascii') + b'\0' + hashlib.sha256(data).digest())
            write_blob(stage_fd, parts, mode, data)

        digest, _ = scan_candidate(candidate, sink=copy)
        if digest != payload['expectedDigest'] or substitutions != 1:
            raise ValueError('Source fingerprint or selected file changed.')
        check_stop()
        current = open_directory_no_links(destination)
        try:
            info = os.fstat(current)
            if (info.st_dev, info.st_ino) != (parent_identity.st_dev, parent_identity.st_ino):
                raise ValueError('Destination changed during proposal.')
        finally:
            os.close(current)
        # The owned run must remain at its selected destination before publication.
        observed = os.stat(run, dir_fd=parent_fd, follow_symlinks=False)
        own = os.fstat(run_fd)
        if (observed.st_dev, observed.st_ino) != (own.st_dev, own.st_ino):
            raise ValueError('Proposal run changed during writing.')
        stage_digest, _ = scan_candidate(destination / run / 'incomplete', allow_incomplete=True)
        if stage_digest != output_hash.hexdigest():
            raise ValueError('Written snapshot differs from the proposal.')
        check_stop()
        exclusive_rename(run_fd, 'incomplete', candidate.name)
        ready = destination / run / candidate.name
        output_digest = fingerprint(ready)
        if output_digest != output_hash.hexdigest():
            raise ValueError('Published snapshot differs from the proposal.')
        named = open_directory_no_links(ready)
        try:
            output_info = os.fstat(named)
            stage_info = os.fstat(stage_fd)
            if (output_info.st_dev, output_info.st_ino) != (stage_info.st_dev, stage_info.st_ino):
                raise ValueError('Published candidate identity changed.')
        finally:
            os.close(named)
        check_stop()
        return {'schemaVersion': 1, 'path': str(ready), 'digest': output_digest,
                'sourceDigest': digest, 'file': name, 'afterHash': payload['afterHash']}
    except (OSError, ValueError, KeyboardInterrupt) as error:
        raise ValueError('Proposal unavailable. Inspect the selected destination for incomplete or unverified output.') from error
    finally:
        for descriptor in (stage_fd, run_fd, parent_fd):
            if descriptor is not None:
                os.close(descriptor)


def read_proposal_payload(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ValueError('Expected a regular proposal payload.')
        with os.fdopen(os.dup(descriptor), 'rb') as stream:
            data = stream.read(131073)
        if len(data) > 131072:
            raise ValueError('Proposal payload exceeds limits.')
        return json.loads(data)
    finally:
        os.close(descriptor)


def main(argv=None):
    if argv is None:
        argv = sys.argv[1:]
    if len(argv) == 3 and argv[0] == '--proposal-read':
        try:
            print(json.dumps(proposal_read(Path(argv[1]), argv[2])))
            return 0
        except (OSError, ValueError, UnicodeError):
            print('Proposal source unavailable. Check source path and limits.', file=sys.stderr)
            return 1
    if len(argv) == 2 and argv[0] == '--proposal-apply':
        try:
            print(json.dumps(apply_proposal(read_proposal_payload(argv[1]))))
            return 0
        except (OSError, ValueError, UnicodeError):
            print('Proposal unavailable. Inspect the destination for incomplete or unverified output.', file=sys.stderr)
            return 1
    if len(argv) == 6 and argv[0] == '--review-file':
        try:
            print(json.dumps(review_file(Path(argv[1]), Path(argv[2]), argv[3], argv[4], argv[5])))
            return 0
        except (OSError, ValueError, UnicodeError):
            print('Candidate file review unavailable. Review the baseline and candidate again.', file=sys.stderr)
            return 1
    if len(argv) == 4 and argv[0] == '--compare':
        try:
            print(json.dumps(compare_candidate(Path(argv[1]), Path(argv[2]), argv[3])))
            return 0
        except (OSError, ValueError, UnicodeError):
            print('Candidate comparison unavailable. Verify the baseline and candidate limits.', file=sys.stderr)
            return 1
    if len(argv) == 2 and argv[0] == '--fingerprint':
        try:
            print(fingerprint(Path(argv[1])))
            return 0
        except (OSError, ValueError):
            print('Candidate fingerprint unavailable.', file=sys.stderr)
            return 1
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
    signal.signal(signal.SIGTERM, request_stop)
    raise SystemExit(main())
