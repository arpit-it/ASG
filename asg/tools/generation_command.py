# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Run one fixed Flutter operation with a deadline and owned process-group cleanup."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import tempfile
import platform
import fcntl

COMMAND_TIMEOUT_SECONDS = 180
OUTPUT_LIMIT_BYTES = 65536

OPERATIONS = {
    'resolve': ['pub', 'get', '--offline'],
    'analyze': ['analyze', '--no-pub'],
    'test': ['test', '--no-pub'],
    'build': ['build', 'web', '--no-pub', '--no-web-resources-cdn'],
}

def run(executable, arguments, cwd, timeout, parent_pid=None, environment=None):
    captured = bytearray()
    lock = threading.Lock()
    cancelled = threading.Event()
    output_limit_exceeded = threading.Event()
    previous = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous[sig] = signal.signal(sig, lambda *_: cancelled.set())
    process = None
    timed_out = False
    def signal_group(sig):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        except PermissionError:
            # Darwin can report EPERM for an already reaped/empty group.
            # A live owned root must never be treated as successfully cleaned.
            if process.poll() is None:
                raise
    try:
        environment = environment if environment is not None else dict(os.environ, FLUTTER_SUPPRESS_ANALYTICS='true', DART_SUPPRESS_ANALYTICS='true', FLUTTER_STORAGE_BASE_URL='http://127.0.0.1:1')
        process = subprocess.Popen([executable, *arguments], cwd=cwd, env=environment, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        def consume():
            while True:
                chunk = process.stdout.read1(4096)
                if not chunk:
                    break
                with lock:
                    remaining = OUTPUT_LIMIT_BYTES - len(captured)
                    if len(chunk) > remaining:
                        output_limit_exceeded.set()
                    if remaining > 0:
                        captured.extend(chunk[:remaining])
        reader = threading.Thread(target=consume, daemon=True)
        reader.start()
        deadline = time.monotonic() + timeout
        while process.poll() is None:
            if parent_pid and os.getppid() != parent_pid:
                cancelled.set()
            if output_limit_exceeded.is_set() or cancelled.is_set() or time.monotonic() >= deadline:
                timed_out = time.monotonic() >= deadline
                break
            time.sleep(0.05)
        # Always clean descendants too, even if a parent exited leaving workers.
        signal_group(signal.SIGTERM)
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        signal_group(signal.SIGKILL)
        reader.join(timeout=2)
        if parent_pid and os.getppid() != parent_pid:
            cancelled.set()
        with lock:
            output = bytes(captured).decode('utf-8', errors='replace')
        return {'exitCode': -1 if timed_out or cancelled.is_set() or output_limit_exceeded.is_set() else process.returncode,
                'cancelled': cancelled.is_set(), 'timedOut': timed_out, 'outputLimitExceeded': output_limit_exceeded.is_set(), 'output': output}
    finally:
        if process is not None:
            signal_group(signal.SIGKILL)
            process.wait(timeout=2)
            process.stdout.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)

def candidate_profile(directory, sdk, pub_cache, temporary):
    # Seatbelt restrictions are inherited by all spawned tool/test processes.
    # No candidate-controlled path is interpolated as profile syntax.
    def subpath(value):
        return '(subpath ' + json.dumps(str(value)) + ')'
    reads = [directory, sdk, pub_cache, temporary, '/System', '/usr', '/bin',
             '/sbin', '/Library', '/private/etc', '/private/var/db', '/private/preboot', '/dev']
    return '\n'.join([
        '(version 1)', '(deny default)',
        '(allow process-exec process-fork sysctl-read)',
        '(deny syscall-unix (syscall-number SYS_setsid SYS_setpgid SYS_posix_spawn))',
        '(allow signal (target same-sandbox))',
        '(allow mach-lookup (global-name "com.apple.cfprefsd.daemon") '
        '(global-name "com.apple.system.logger") (global-name "com.apple.logd") '
        '(global-name "com.apple.trustd"))',
        '(allow file-read-metadata)', '(allow file-read-data (literal "/"))',
        '(allow file-read* ' + ' '.join(map(subpath, reads)) + ')',
        '(allow file-write* ' + subpath(directory) + ' ' + subpath(temporary) +
        ' (literal "/dev/null"))',
        '(allow network-inbound (local ip "localhost:*"))',
        '(allow network-outbound (remote ip "localhost:*"))',
    ])


def confined_operation(directory, sdk, operation, timeout, parent_pid):
    if platform.system() != 'Darwin' or not Path('/usr/bin/sandbox-exec').is_file():
        raise RuntimeError('Confined candidate verification requires macOS sandbox-exec')
    sdk = Path(sdk).resolve(strict=True)
    pub_cache = Path(os.environ.get('PUB_CACHE', str(Path.home() / '.pub-cache'))).resolve(strict=True)
    # Refuse cache/tool roots overlapping the candidate or private home itself.
    home = Path.home().resolve()
    if pub_cache == home or sdk == home or directory == home or directory in sdk.parents or directory in pub_cache.parents:
        raise ValueError('Unsafe candidate tool/cache roots')
    dart = sdk / 'bin/cache/dart-sdk/bin/dart'
    snapshot = sdk / 'bin/cache/flutter_tools.snapshot'
    packages = sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
    if not all(p.is_file() for p in (dart, snapshot, packages)):
        raise ValueError('Confined verification requires initialized cached Flutter tools')
    with tempfile.TemporaryDirectory(prefix='asg-confined-') as temp:
        temporary = Path(temp).resolve()
        (temporary / 'home').mkdir()
        profile = temporary / 'candidate.sb'
        profile.write_text(candidate_profile(directory, sdk, pub_cache, temporary))
        # Package content stays read-only. Pub's active_roots bookkeeping lives
        # in a candidate-local overlay that remains valid across the four steps.
        cache = directory / '.dart_tool' / 'asg_pub_cache'
        for folder in (directory / '.dart_tool', cache):
            if folder.is_symlink():
                raise ValueError('Linked candidate cache refused')
            folder.mkdir(exist_ok=True)
            if folder.resolve() != folder:
                raise ValueError('Candidate cache path changed')
        for name in ('hosted', 'hosted-hashes', 'git'):
            source = pub_cache / name
            target = cache / name
            if source.exists():
                if not target.exists() and not target.is_symlink():
                    target.symlink_to(source, target_is_directory=True)
                if not target.is_symlink() or target.resolve() != source.resolve():
                    raise ValueError('Unexpected candidate package overlay')
        environment = {
            'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
            'HOME': str(temporary / 'home'), 'TMPDIR': str(temporary) + '/',
            'PUB_CACHE': str(cache), 'FLUTTER_ROOT': str(sdk),
            'FLUTTER_SUPPRESS_ANALYTICS': 'true', 'DART_SUPPRESS_ANALYTICS': 'true',
            'CI': 'true', 'LANG': 'en_US.UTF-8', 'FLUTTER_ALREADY_LOCKED': 'true',
            'FLUTTER_STORAGE_BASE_URL': 'http://127.0.0.1:1',
        }
        # Trusted supervisor owns the existing SDK cache lock; sandboxed tools
        # inherit no writable SDK descriptor and cannot update the SDK/cache.
        lock = (sdk / 'bin/cache/lockfile').open('r+b')
        deadline = time.monotonic() + timeout
        try:
            while True:
                try:
                    fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError('Flutter SDK cache lock deadline exceeded')
                    time.sleep(0.05)
            return run('/usr/bin/sandbox-exec', [
            '-f', str(profile), str(dart), '--packages=' + str(packages),
            str(snapshot), '--no-version-check', *OPERATIONS[operation],
        ], str(directory), max(1, deadline - time.monotonic()), parent_pid, environment)
        finally:
            lock.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--operation', choices=OPERATIONS, required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--confined', action='store_true')
    parser.add_argument('--directory', required=True)
    parser.add_argument('--timeout', type=int, choices=[COMMAND_TIMEOUT_SECONDS], default=COMMAND_TIMEOUT_SECONDS)
    parser.add_argument('--output-limit', type=int, choices=[OUTPUT_LIMIT_BYTES], default=OUTPUT_LIMIT_BYTES)
    args = parser.parse_args()
    directory = Path(args.directory)
    if not directory.is_absolute() or directory.resolve() != directory or not directory.is_dir():
        raise ValueError('Expected a canonical generated project directory')
    executable = Path(args.sdk) / 'bin/flutter'
    result = (confined_operation(directory, args.sdk, args.operation, args.timeout, os.getppid())
              if args.confined else run(str(executable), ['--no-version-check', *OPERATIONS[args.operation]], str(directory), args.timeout, os.getppid()))
    print(json.dumps(result))

if __name__ == '__main__':
    main()
