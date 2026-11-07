# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha

"""Synthetic-only macOS runner boundary. No candidate or caller command API.

This is an isolation prerequisite exerciser, deliberately absent from application
operations. Authored fixtures, compiler and engine have distinct private stages.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import resource
import secrets
import select
import signal
import socket
import stat
import subprocess
import tempfile
import threading
import time

FIXTURES = {
    'hook_probe.dart': '10f7512941747836c6c5266803bcdff767b2bde0dd64f25875124fe8a17284bc',
    'engine_probe.dart': '65d26b49755c4c261fa6460c5d2df9cdfa44f33f74aa8a2492b13529d579e0ff',
}
FRAMEWORK = '5fc346839b5d0eef006ed8404392afb4dfae428d'
MODES = ('positive', 'timeout', 'cancel', 'output', 'malformed')
OUTPUT_LIMIT = 65536
FRAME_LIMIT = 4096
MAX_KERNEL = 32 * 1024 * 1024


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular_bytes(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > limit:
            raise ValueError('Expected a bounded single-link regular file')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError('File exceeds limit')
        return data
    finally:
        os.close(fd)


def canonical_directory(path):
    path = Path(path)
    if not path.is_absolute() or path.resolve(strict=True) != path or not path.is_dir():
        raise ValueError('Expected a canonical directory')
    current = Path('/')
    for part in path.parts[1:]:
        current /= part
        if current.is_symlink():
            raise ValueError('Linked directory refused')
    return path


def fixture_sources():
    root = Path(__file__).resolve().parent / 'f12_runner_fixtures'
    result = {}
    for name, expected in FIXTURES.items():
        data = regular_bytes(root / name, 16384)
        if digest(data) != expected:
            raise ValueError('Bundled fixture identity differs')
        result[name] = data
    return result


def toolchain(sdk):
    sdk = canonical_directory(sdk)
    version = json.loads(regular_bytes(sdk / 'bin/cache/flutter.version.json', 16384))
    if version.get('frameworkRevision') != FRAMEWORK:
        raise ValueError('This boundary requires the explicitly reviewed Flutter revision')
    engine = sdk / 'bin/cache/artifacts/engine/darwin-x64'
    paths = {
        'dart': sdk / 'bin/cache/dart-sdk/bin/dart',
        'aot': sdk / 'bin/cache/dart-sdk/bin/dartaotruntime',
        'frontend': engine / 'frontend_server_aot.dart.snapshot',
        'engine': engine / 'flutter_tester',
        'icu': engine / 'icudtl.dat',
        'platform': sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk/platform_strong.dill',
    }
    hashes = {}
    for key, path in paths.items():
        if path.resolve(strict=True) != path:
            raise ValueError('Linked tool refused')
        hashes[key] = digest(regular_bytes(path, 256 * 1024 * 1024))
    for key in ('dart', 'aot', 'engine'):
        if not os.access(paths[key], os.X_OK):
            raise ValueError('Required executable unavailable')
    return sdk, version, paths, hashes


class OwnedPorts:
    """Reserve both loopback address families for one exact numeric TCP port."""
    def __init__(self):
        self.sockets = []
        try:
            v4 = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self.sockets.append(v4)
            v4.bind(('127.0.0.1', 0))
            self.port = v4.getsockname()[1]
            v6 = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
            self.sockets.append(v6)
            v6.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            v6.bind(('::1', self.port))
            for item in self.sockets:
                item.listen(4)
                item.setblocking(False)
        except BaseException:
            self.close()
            raise

    def close(self):
        for item in self.sockets:
            item.close()
        self.sockets = []


def profile(sdk, source, writable, *, kernel=None, port=None):
    reads = [sdk, source, writable, '/System', '/usr', '/bin', '/sbin',
             '/Library', '/private/etc', '/private/var/db', '/private/preboot', '/dev']
    if kernel is not None:
        reads.append(kernel)
    subpaths = ' '.join('(subpath ' + json.dumps(str(p)) + ')' for p in reads)
    rules = [
        '(version 1)', '(deny default)',
        # No subprocess authority: fixed compiler/hook/engine need threads only.
        '(allow process-exec sysctl-read)',
        '(deny syscall-unix (syscall-number SYS_setsid SYS_setpgid SYS_posix_spawn))',
        '(allow signal (target same-sandbox))',
        '(allow mach-lookup (global-name "com.apple.cfprefsd.daemon") '
        '(global-name "com.apple.system.logger") (global-name "com.apple.logd") '
        '(global-name "com.apple.trustd"))',
        '(allow file-read-metadata)', '(allow file-read-data (literal "/"))',
        '(allow file-read* ' + subpaths + ')',
        '(allow file-write* (subpath ' + json.dumps(str(writable)) + ') (literal "/dev/null"))',
    ]
    if port is not None:
        if type(port) is not int or not 1 <= port <= 65535:
            raise ValueError('Invalid owned IPC port')
        rules.append('(allow network-outbound (remote ip "localhost:%d"))' % port)
    return '\n'.join(rules) + '\n'


def limits():
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CPU, (20, 20))
    resource.setrlimit(resource.RLIMIT_FSIZE, (MAX_KERNEL, MAX_KERNEL))
    resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))


def run_stage(argv, cwd, env, policy, *, timeout=30, cancel_after=None):
    """Fixed trusted stage only; bounded pipe reader and unconditional group reap."""
    if not 0 < timeout <= 30:
        raise ValueError('Invalid stage deadline')
    policy_path = cwd / 'policy.sb'
    policy_path.write_text(policy)
    policy_path.chmod(0o600)
    output = bytearray()
    overflow = threading.Event()
    stop = threading.Event()
    previous = {}
    if threading.current_thread() is threading.main_thread():
        for sig in (signal.SIGTERM, signal.SIGINT):
            previous[sig] = signal.signal(sig, lambda *_: stop.set())
    process = None
    started = time.monotonic()
    reason = None
    def kill_group(sig):
        if process is not None:
            try:
                os.killpg(process.pid, sig)
            except ProcessLookupError:
                pass
    try:
        process = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(policy_path), *map(str, argv)],
                                   cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   start_new_session=True, preexec_fn=limits, close_fds=True)
        def read():
            while True:
                data = process.stdout.read1(4096)
                if not data:
                    return
                remaining = OUTPUT_LIMIT - len(output)
                output.extend(data[:remaining])
                if len(data) > remaining:
                    overflow.set()
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        while process.poll() is None:
            elapsed = time.monotonic() - started
            if stop.is_set() or (cancel_after is not None and elapsed >= cancel_after):
                reason = 'cancelled'
            elif overflow.is_set():
                reason = 'outputLimit'
            elif elapsed >= timeout:
                reason = 'deadline'
            if reason:
                break
            time.sleep(0.02)
        kill_group(signal.SIGTERM)
        try:
            process.wait(timeout=0.3)
        except subprocess.TimeoutExpired:
            pass
        kill_group(signal.SIGKILL)
        process.wait(timeout=2)
        reader.join(timeout=2)
        if reader.is_alive():
            reason = 'unsettledOutput'
        if overflow.is_set():
            reason = 'outputLimit'
        try:
            os.killpg(process.pid, 0)
            clean = False
        except ProcessLookupError:
            clean = True
        return {'exitCode': process.returncode, 'reason': reason,
                'elapsedSeconds': time.monotonic() - started, 'output': output.decode('utf8', 'replace'),
                'outputBytes': len(output), 'groupReaped': clean,
                'profileSha256': digest(policy.encode()), 'argv': list(map(str, argv))}
    finally:
        if process is not None:
            kill_group(signal.SIGKILL)
            process.wait(timeout=2)
            process.stdout.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def broker_message(data, *, nonce, source_hash, kernel_hash):
    if len(data) > FRAME_LIMIT or not data.endswith(b'\n') or data.count(b'\n') != 1:
        raise ValueError('Invalid broker frame')
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('Duplicate broker key')
            value[key] = item
        return value
    value = json.loads(data, object_pairs_hook=unique)
    expected = {'schemaVersion', 'stage', 'family', 'nonce', 'sourceHash', 'kernelHash', 'observations'}
    observations = {'engineApi', 'readDenied', 'writeDenied', 'spawnDenied', 'canaryV4Denied', 'canaryV6Denied'}
    if (not isinstance(value, dict) or set(value) != expected or type(value['schemaVersion']) is not int
            or value['schemaVersion'] != 1 or value['stage'] != 'engine'
            or value['family'] not in ('127.0.0.1', '::1') or value['nonce'] != nonce
            or value['sourceHash'] != source_hash or value['kernelHash'] != kernel_hash
            or not isinstance(value['observations'], dict) or set(value['observations']) != observations
            or not all(type(v) is bool and v for v in value['observations'].values())):
        raise ValueError('Broker observation differs from fixed session')
    return value


def observe_ports(owned, canary):
    """Drain fixed small frames after the engine settles; never run a server command.

    The listener backlog accepts at most the fixture's two short sends while the
    child runs. No broker thread exists across fork/preexec resource setup.
    """
    listeners = owned.sockets + canary.sockets
    records = []
    deadline = time.monotonic() + 1
    while time.monotonic() < deadline:
        ready, _, _ = select.select(listeners, [], [], 0.05)
        if not ready:
            return records
        for listener in ready:
            connection, _ = listener.accept()
            connection.settimeout(0.2)
            data = bytearray()
            incomplete = False
            try:
                while len(data) <= FRAME_LIMIT:
                    chunk = connection.recv(min(1024, FRAME_LIMIT + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
            except (TimeoutError, OSError):
                incomplete = True
            finally:
                connection.close()
            records.append({'canary': listener in canary.sockets, 'data': bytes(data), 'incomplete': incomplete, 'family': '127.0.0.1' if listener.family == socket.AF_INET else '::1'})
            if len(records) > 4:
                return records
    raise ValueError('Broker drain deadline exceeded')


def exercise(sdk_path, *, mode='positive'):
    """Execute bundled authored fixtures only. Not an ASG candidate runner."""
    if (mode not in MODES or platform.system() != 'Darwin'
            or threading.current_thread() is not threading.main_thread() or threading.active_count() != 1):
        raise ValueError('Synthetic Mac fixture unavailable')
    sources = fixture_sources()  # Hash identity before any process or output.
    sdk, version, tools, tool_hashes = toolchain(sdk_path)
    root = Path(tempfile.mkdtemp(prefix='asg-f12-boundary-')).resolve()
    root.chmod(0o700)
    stage_dirs = {}
    for name in ('source', 'hook', 'compile', 'engine'):
        stage_dirs[name] = root / name
        stage_dirs[name].mkdir(mode=0o700)
    for name, data in sources.items():
        target = stage_dirs['source'] / name
        target.write_bytes(data)
        target.chmod(0o400)
    sentinel = root / 'outside-private-sentinel'
    sentinel.write_text('original-private-sentinel')
    sentinel.chmod(0o600)
    original_hash = digest(sentinel.read_bytes())
    report = {'schemaVersion': 1, 'kind': 'fixed-synthetic-boundary-only', 'candidateExecutionEnabled': False,
              'run': str(root), 'mode': mode, 'sdkVersion': version, 'toolHashes': tool_hashes,
              'fixtureHashes': FIXTURES, 'helperSha256': digest(Path(__file__).read_bytes()),
              'limits': {'stageWallSeconds': 30, 'outputBytes': OUTPUT_LIMIT, 'brokerFrameBytes': FRAME_LIMIT,
                         'cpuSecondsPerProcess': 20, 'fileBytesPerFile': MAX_KERNEL, 'openFiles': 128,
                         'processFork': 'denied', 'memory': 'not bounded; arbitrary candidate execution disabled'}}
    owned = canary = None
    records = []
    try:
        owned, canary = OwnedPorts(), OwnedPorts()
        report['ports'] = {'broker': owned.port, 'canary': canary.port, 'families': ['IPv4', 'IPv6']}
        base_env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LANG': 'en_US.UTF-8',
                    'SENTINEL': str(sentinel), 'BROKER_PORT': str(owned.port), 'CANARY_PORT': str(canary.port)}
        def environment(stage):
            return dict(base_env, HOME=str(stage_dirs[stage]), TMPDIR=str(stage_dirs[stage]) + '/')
        hook_policy = profile(sdk, stage_dirs['source'], stage_dirs['hook'])
        report['hook'] = run_stage([tools['dart'], '--disable-dart-dev', stage_dirs['source'] / 'hook_probe.dart'],
                                  stage_dirs['hook'], environment('hook'), hook_policy)
        hook = report['hook']
        if hook['exitCode'] != 0 or hook['reason'] or not hook['groupReaped']:
            raise ValueError('Fixed hook stage failed')
        hook_observations = json.loads(hook['output'])
        if hook_observations != {k: True for k in ('readDenied', 'writeDenied', 'spawnDenied', 'networkDenied')}:
            raise ValueError('Fixed hook did not establish expected denials')
        kernel = stage_dirs['compile'] / 'engine.dill'
        compiler_policy = profile(sdk, stage_dirs['source'], stage_dirs['compile'])
        report['compile'] = run_stage([tools['aot'], tools['frontend'], '--sdk-root',
            tools['platform'].parent, '--target=flutter', '--no-link-platform', '--output-dill', kernel,
            stage_dirs['source'] / 'engine_probe.dart'], stage_dirs['compile'], environment('compile'), compiler_policy)
        compiled = report['compile']
        if compiled['exitCode'] != 0 or compiled['reason'] or not compiled['groupReaped']:
            raise ValueError('Fixed compiler stage failed')
        kernel_data = regular_bytes(kernel, MAX_KERNEL)
        if not kernel_data or kernel_data[:4] != b'\x90\xab\xcd\xef':
            raise ValueError('Expected compiled kernel')
        kernel.chmod(0o400)
        kernel_hash = digest(kernel_data)
        report['kernelSha256'] = kernel_hash
        # Revalidate immutable fixture/tool inputs before crossing into engine.
        for name, data in sources.items():
            if regular_bytes(stage_dirs['source'] / name, 16384) != data:
                raise ValueError('Staged source changed')
        if toolchain(sdk)[3] != tool_hashes or digest(regular_bytes(kernel, MAX_KERNEL)) != kernel_hash:
            raise ValueError('Tool or kernel identity changed')
        nonce = secrets.token_hex(32)
        env = dict(environment('engine'), SESSION_NONCE=nonce, SOURCE_HASH=FIXTURES['engine_probe.dart'],
                   KERNEL_HASH=kernel_hash, PROBE_MODE=mode, FLUTTER_TEST='true')
        engine_policy = profile(sdk, stage_dirs['source'], stage_dirs['engine'], kernel=kernel, port=owned.port)
        report['engine'] = run_stage([tools['engine'], '--disable-vm-service', '--enable-software-rendering',
            '--skia-deterministic-rendering', '--non-interactive', '--icu-data-file-path=' + str(tools['icu']), kernel],
            stage_dirs['engine'], env, engine_policy,
            timeout=1 if mode in ('timeout', 'cancel') else 10,
            cancel_after=0.2 if mode == 'cancel' else None)
        records = observe_ports(owned, canary)
        report['canaryConnections'] = sum(x['canary'] for x in records)
        if any(x['incomplete'] for x in records):
            raise ValueError('Incomplete broker frame')
        messages = [broker_message(x['data'], nonce=nonce, source_hash=FIXTURES['engine_probe.dart'],
                                   kernel_hash=kernel_hash) for x in records if not x['canary'] and 'data' in x]
        if any(message['family'] != record['family'] for message, record in zip(messages, [r for r in records if not r['canary']])):
            raise ValueError('Broker connection family differs')
        engine = report['engine']
        report['engineMessages'] = messages
        positive = (engine['exitCode'] == 0 and engine['reason'] is None and engine['groupReaped']
                    and len(messages) == 2 and {x['family'] for x in messages} == {'127.0.0.1', '::1'}
                    and not report['canaryConnections'] and len(records) == 2)
        report['pass'] = positive if mode == 'positive' else False
        if mode in ('timeout', 'cancel', 'output'):
            expected = {'timeout': 'deadline', 'cancel': 'cancelled', 'output': 'outputLimit'}[mode]
            report['adverseCaseObserved'] = engine['reason'] == expected and engine['groupReaped'] and not messages
    except (OSError, ValueError, RuntimeError) as error:
        report['pass'] = False
        report['failure'] = str(error)
        if mode == 'malformed' and 'engine' in report:
            report['adverseCaseObserved'] = 'Broker observation' in str(error) and report['engine']['groupReaped']
    finally:
        if owned:
            owned.close()
        if canary:
            canary.close()
        report['sentinelPreserved'] = digest(sentinel.read_bytes()) == original_hash
        report['sourcesPreserved'] = all(regular_bytes(stage_dirs['source'] / n, 16384) == b for n, b in sources.items())
        report['brokerSettled'] = True
        try:
            report['toolsPreserved'] = toolchain(sdk)[3] == tool_hashes
        except (OSError, ValueError):
            report['toolsPreserved'] = False
        report['pass'] = bool(report.get('pass') and report['sentinelPreserved'] and report['sourcesPreserved']
                              and report['brokerSettled'] and report['toolsPreserved'])
        if report.get('adverseCaseObserved'):
            report['adverseCaseObserved'] = all(report[k] for k in ('sentinelPreserved', 'sourcesPreserved', 'toolsPreserved'))
        report['limitations'] = ['Synthetic fixtures only; no application operation or arbitrary source API.',
            'Hook fixture is authored Dart, not a general package-hook pipeline.',
            'Custom fixed TCP fixture protocol is not stock Flutter test WebSocket transport.',
            'No memory/aggregate-disk/resource-exhaustion or hostile same-user tampering guarantee.',
            'No arbitrary ASG candidate or full F12 acceptance claim.']
        (root / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synthetic-fixture', action='store_true', required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--case', choices=MODES, default='positive')
    args = parser.parse_args(argv)
    result = exercise(args.sdk, mode=args.case)
    print(json.dumps(result))
    return 0 if result.get('pass') or result.get('adverseCaseObserved') else 1


if __name__ == '__main__':
    raise SystemExit(main())
