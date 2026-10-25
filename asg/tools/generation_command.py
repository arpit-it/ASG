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

OUTPUT_LIMIT_BYTES = 65536

OPERATIONS = {
    'resolve': ['pub', 'get', '--offline'],
    'analyze': ['analyze', '--no-pub'],
    'test': ['test', '--no-pub'],
    'build': ['build', 'web', '--no-pub', '--no-web-resources-cdn'],
}

def run(executable, arguments, cwd, timeout, parent_pid=None):
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
        environment = dict(os.environ, FLUTTER_SUPPRESS_ANALYTICS='true', DART_SUPPRESS_ANALYTICS='true', FLUTTER_STORAGE_BASE_URL='http://127.0.0.1:1')
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

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--operation', choices=OPERATIONS, required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--directory', required=True)
    parser.add_argument('--timeout', type=int, default=180)
    parser.add_argument('--output-limit', type=int, choices=[OUTPUT_LIMIT_BYTES], default=OUTPUT_LIMIT_BYTES)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300:
        raise ValueError('Invalid deadline')
    directory = Path(args.directory)
    if not directory.is_absolute() or directory.resolve() != directory or not directory.is_dir():
        raise ValueError('Expected a canonical generated project directory')
    executable = Path(args.sdk) / 'bin/flutter'
    result = run(str(executable), ['--no-version-check', *OPERATIONS[args.operation]], str(directory), args.timeout, os.getppid())
    print(json.dumps(result))

if __name__ == '__main__':
    main()
