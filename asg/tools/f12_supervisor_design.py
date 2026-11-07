# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Fixed authored supervisor design probe; never an application candidate API."""
import argparse
import base64
import hashlib
import json
import multiprocessing
import threading
import os
from pathlib import Path
import re
import secrets
import signal
import socket
import struct
import tempfile
import time
from urllib.parse import unquote, urlparse

import f12_runner_boundary as boundary

FIXTURES = {'package_hook.dart': '72fcd0c5a6d4aeba6ed4a05663646952cb31abb9a54b490397a42adeee1abac1', 'protocol.dart': 'f0f3b80b1f84274e3746bb688d1aa8ef1dc82a46a8f84d66f10b3bb05a2e9ed5', 'engine.dart': 'b0d96efe0e21cba543d1b14d52a443c980c09fc1b4aac7a57f34a4d8edee5549'}
CASES = ('positive', 'hook-timeout', 'hook-output', 'wrong-token', 'extra-frame', 'engine-timeout', 'stop')
MAX_FRAME = 4096


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate key')
        result[key] = value
    return result


def strict_json(data):
    return json.loads(data, object_pairs_hook=unique, parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Invalid number')))


def exact_read(connection, count):
    if not 0 <= count <= MAX_FRAME:
        raise ValueError('Frame bound')
    result = b''
    while len(result) < count:
        part = connection.recv(count - len(result))
        if not part:
            raise ValueError('Truncated frame')
        result += part
    return result


def upgrade(connection, token):
    data = bytearray()
    while not data.endswith(b'\r\n\r\n'):
        if len(data) >= MAX_FRAME:
            raise ValueError('Upgrade bound')
        data.extend(exact_read(connection, 1))
    lines = data.decode('ascii').split('\r\n')
    if lines[0] != 'GET /' + token + ' HTTP/1.1':
        raise ValueError('Wrong session path')
    headers = {}
    for line in lines[1:-2]:
        key, value = line.split(':', 1)
        key = key.lower()
        if key in headers:
            raise ValueError('Duplicate header')
        headers[key] = value.strip()
    if (headers.get('upgrade', '').lower() != 'websocket'
            or headers.get('connection', '').lower() != 'upgrade'
            or headers.get('sec-websocket-version') != '13' or 'origin' in headers
            or 'sec-websocket-protocol' in headers):
        raise ValueError('Upgrade refused')
    key = headers.get('sec-websocket-key', '')
    if len(base64.b64decode(key, validate=True)) != 16:
        raise ValueError('WebSocket key')
    accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
    connection.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')


def frame(connection, *, close=False):
    first, second = exact_read(connection, 2)
    expected = 0x88 if close else 0x81
    if first != expected or not second & 0x80:
        raise ValueError('Only final masked text/close frames allowed')
    length = second & 0x7f
    if length == 127:
        raise ValueError('Large frame')
    if length == 126:
        length = struct.unpack('!H', exact_read(connection, 2))[0]
        if length < 126:
            raise ValueError('Noncanonical length')
    if length > (125 if close else MAX_FRAME):
        raise ValueError('Frame bound')
    mask = exact_read(connection, 4)
    payload = exact_read(connection, length)
    payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    if close:
        if len(payload) == 1:
            raise ValueError('Invalid close')
        if len(payload) >= 2 and struct.unpack('!H', payload[:2])[0] != 1000:
            raise ValueError('Unexpected close status')
        payload[2:].decode('utf8')
        connection.sendall(b'\x88' + bytes([len(payload)]) + payload)
    return payload


def session_message(data, expected):
    value = strict_json(data.decode('utf8'))
    if (type(value) is not dict or set(value) != {'schema', 'session', 'source', 'kernel', 'engine'}
            or type(value['schema']) is not int or value['schema'] != 1
            or value['session'] != expected['session'] or value['source'] != expected['source']
            or value['kernel'] != expected['kernel'] or value['engine'] is not True):
        raise ValueError('Session evidence differs')
    return value


def broker(sockets, destination, expected):
    """Trusted separate process; no thread exists across confined child launch."""
    result = {'accepted': [], 'pass': False}
    try:
        boundary.limits()
        deadline = time.monotonic() + 12
        for listener in sockets:
            listener.setblocking(True)
            listener.settimeout(max(.01, deadline - time.monotonic()))
            connection, _ = listener.accept()
            with connection:
                connection.settimeout(2)
                upgrade(connection, expected['session'])
                session_message(frame(connection), expected)
                frame(connection, close=True)  # Reject extra/replayed/binary/control frames.
            result['accepted'].append('IPv4' if listener.family == socket.AF_INET else 'IPv6')
        result['pass'] = True
    except (OSError, ValueError, UnicodeError, KeyError) as error:
        result['error'] = str(error)
        result['errorType'] = type(error).__name__
    finally:
        Path(destination).write_text(json.dumps(result))
        for listener in sockets:
            listener.close()


def fixtures():
    root = Path(__file__).parent / 'f12_supervisor_fixtures'
    result = {name: boundary.regular_bytes(root / name, 16384) for name in FIXTURES}
    if any(boundary.digest(data) != FIXTURES[name] for name, data in result.items()):
        raise ValueError('Fixture identity differs')
    return result


def dependencies(sdk, destination):
    """Copy bounded installed Dart library closure; no pub/network/SDK mutation."""
    config = sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
    entries = strict_json(boundary.regular_bytes(config, 1024 * 1024))['packages']
    roots = {entry['name']: (config.parent / unquote(urlparse(entry['rootUri']).path)).resolve() for entry in entries}
    pending, copied, files, size = ['hooks'], {}, 0, 0
    while pending:
        name = pending.pop()
        if name in copied:
            continue
        if not re.fullmatch(r'[a-z_][a-z0-9_]*', name) or name not in roots:
            raise ValueError('Unknown installed dependency: ' + name)
        root = roots[name]
        pubspec = boundary.regular_bytes(root / 'pubspec.yaml', 32768)
        if name == 'hooks' and not re.search(rb'^version: 2\.0\.2$', pubspec, re.M):
            raise ValueError('Unknown hooks API')
        observed = {}
        for source in sorted((root / 'lib').rglob('*')):
            if source.is_dir():
                if source.is_symlink():
                    raise ValueError('Linked package directory')
                continue
            if source.suffix != '.dart':
                continue
            data = boundary.regular_bytes(source, 1024 * 1024)
            files += 1
            size += len(data)
            if files > 1500 or size > 20 * 1024 * 1024:
                raise ValueError('Dependency copy bound')
            relative = source.relative_to(root)
            target = destination / name / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            target.chmod(0o400)
            observed[str(relative)] = boundary.digest(data)
            pending.extend(x.decode() for x in re.findall(rb"(?m)^(?:import|export)\s+['\"]package:([a-z0-9_]+)/", data))
        copied[name] = {'pubspec': boundary.digest(pubspec), 'files': observed}
    value = {'configVersion': 2, 'packages': [{'name': name, 'rootUri': (destination / name).as_uri() + '/', 'packageUri': 'lib/', 'languageVersion': '3.10'} for name in sorted(copied)]}
    path = destination / 'package_config.json'
    path.write_text(json.dumps(value))
    path.chmod(0o400)
    return path, copied


def hook_output(path):
    value = strict_json(boundary.regular_bytes(path, 16384))
    if (type(value) is not dict or not set(value) <= {'timestamp', 'status', 'assets_for_linking'}
            or not isinstance(value.get('timestamp'), str) or len(value['timestamp']) > 64
            or value.get('status', 'success') != 'success' or value.get('assets_for_linking', {}) != {}):
        raise ValueError('Fixed no-assets hook output refused')
    return value


def expected_failure(case, report):
    stages = list(report['stages'].values())
    last = stages[-1] if stages else {}
    return ((case == 'hook-timeout' and not report['engineDispatched'] and last.get('reason') == 'deadline')
        or (case == 'hook-output' and not report['engineDispatched'] and report.get('error') == 'Fixed no-assets hook output refused')
        or (case == 'wrong-token' and report['engineDispatched'] and report.get('broker', {}).get('error') == 'Wrong session path')
        or (case == 'extra-frame' and report['engineDispatched'] and report.get('broker', {}).get('error') == 'Only final masked text/close frames allowed')
        or (case == 'engine-timeout' and report['engineDispatched'] and last.get('reason') == 'deadline')
        or (case == 'stop' and report['engineDispatched'] and last.get('reason') == 'cancelled'))


def exercise(sdk_path, case):
    if case not in CASES or threading.current_thread() is not threading.main_thread() or threading.active_count() != 1:
        raise ValueError('Unknown fixed case')
    authored = fixtures()
    sdk, version, tools, tool_hashes = boundary.toolchain(sdk_path)
    root = Path(tempfile.mkdtemp(prefix='asg-f12-supervisor-')).resolve()
    root.chmod(0o700)
    source = root / 'source'
    source.mkdir(mode=0o700)
    for name, data in authored.items():
        (source / name).write_bytes(data)
        (source / name).chmod(0o400)
    (source / 'hook').mkdir()
    for name in ('build', 'link'):
        target = source / 'hook' / (name + '.dart')
        target.write_bytes(authored['package_hook.dart'])
        target.chmod(0o400)
    packages, package_hashes = dependencies(sdk, source / 'packages')
    sentinel = root / 'outside-sentinel'
    sentinel.write_text('preserved')
    report = {'kind': 'authored-supervisor-design-only', 'candidateExecutionEnabled': False, 'stockFlutterHarnessIntegrated': False,
              'case': case, 'run': str(root), 'helperSha256': boundary.digest(Path(__file__).read_bytes()),
              'baseHelperSha256': boundary.digest(Path(boundary.__file__).read_bytes()),
              'sdkVersion': version, 'toolHashes': tool_hashes, 'fixtureHashes': FIXTURES,
              'installedPackageHashes': package_hashes, 'stages': {}, 'pass': False, 'engineDispatched': False}
    owned, canary, worker = None, None, None
    pinned = {str(p): boundary.digest(boundary.regular_bytes(p, 1024 * 1024)) for p in source.rglob('*') if p.is_file()}
    stopped = [False]
    previous = {sig: signal.signal(sig, lambda *_: stopped.__setitem__(0, True)) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        owned, canary = boundary.OwnedPorts(), boundary.OwnedPorts()
        report['ports'] = {'broker': owned.port, 'canary': canary.port}
        env = {'PATH': '/usr/bin:/bin', 'LANG': 'en_US.UTF-8', 'SENTINEL': str(sentinel), 'BROKER_PORT': str(owned.port), 'MODE': case, 'CANARY_PORT': str(canary.port)}
        def stage(name, argv, *, input_path=None, timeout=30, cancel=None, port=None):
            if stopped[0]:
                raise ValueError('Supervisor stopped')
            directory = root / name
            directory.mkdir(mode=0o700, exist_ok=True)
            policy = boundary.profile(sdk, source, directory, kernel=input_path, port=port)
            if any(boundary.digest(boundary.regular_bytes(Path(p), 1024 * 1024)) != h for p, h in pinned.items()):
                raise ValueError('Input identity changed')
            if any(boundary.digest(boundary.regular_bytes(Path(p), 256 * 1024 * 1024)) != h for p, h in report.get('hookCompilerHashes', {}).items()):
                raise ValueError('Hook compiler identity changed')
            if any(boundary.digest(boundary.regular_bytes(Path(p), boundary.MAX_KERNEL)) != h for p, h in report.get('hookKernelHashes', {}).items()):
                raise ValueError('Hook kernel identity changed')
            if boundary.toolchain(sdk)[3] != tool_hashes:
                raise ValueError('Tool identity changed')
            result = boundary.run_stage(argv, directory, dict(env, HOME=str(directory), TMPDIR=str(directory) + '/'), policy, timeout=timeout, cancel_after=cancel)
            report['stages'][name + ':' + str(len(report['stages']))] = result
            if result['exitCode'] != 0 or result['reason'] or not result['groupReaped']:
                raise ValueError('Stage refused: ' + name)
            return directory
        # Compile the authored real hooks and trusted protocol helper separately.
        extra_tools = {str(p): boundary.digest(boundary.regular_bytes(p, 256 * 1024 * 1024)) for p in [sdk / 'bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot', sdk / 'bin/cache/dart-sdk/lib/_internal/vm_platform_product.dill']}
        report['hookCompilerHashes'] = extra_tools
        compiled_hashes = {}
        for name in ('build', 'link', 'protocol'):
            directory = root / ('compile-' + name)
            stage('compile-' + name, [tools['aot'], sdk / 'bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot', '--platform=' + str(sdk / 'bin/cache/dart-sdk/lib/_internal/vm_platform_product.dill'), '--packages=' + str(packages), '--output=' + str(directory / 'hook.dill'), source / ('protocol.dart' if name == 'protocol' else 'hook/' + name + '.dart')])
            kernel = directory / 'hook.dill'
            if boundary.regular_bytes(kernel, boundary.MAX_KERNEL)[:4] != b'\x90\xab\xcd\xef':
                raise ValueError('Malformed hook kernel')
            kernel.chmod(0o400)
            compiled_hashes[str(kernel)] = boundary.digest(boundary.regular_bytes(kernel, boundary.MAX_KERNEL))
        report['hookKernelHashes'] = compiled_hashes
        protocol_kernel = root / 'compile-protocol/hook.dill'
        for name in ('build', 'link'):
            hook_kernel = root / ('compile-' + name) / 'hook.dill'
            directory = root / name
            directory.mkdir(mode=0o700)
            (directory / 'shared').mkdir(mode=0o700)
            # Protocol preparation/validation is trusted authored code, outside hook policy authority.
            stage(name, [tools['dart'], protocol_kernel, 'input', directory, name, source], input_path=protocol_kernel)
            input_hash = boundary.digest(boundary.regular_bytes(directory / 'input.json', 16384))
            report.setdefault('hookInputHashes', {})[name] = input_hash
            env['HOOK_STAGE'] = name
            stage(name, [tools['dart'], hook_kernel, '--config=' + str(directory / 'input.json')], input_path=hook_kernel, timeout=1 if case == 'hook-timeout' else 10)
            if boundary.digest(boundary.regular_bytes(directory / 'input.json', 16384)) != input_hash:
                raise ValueError('Hook input changed')
            if case == 'hook-output':
                (directory / 'output.json').write_text('{"timestamp":"now","command":"unexpected"}')
            hook_output(directory / 'output.json')
            report.setdefault('hookOutputHashes', {})[name] = boundary.digest(boundary.regular_bytes(directory / 'output.json', 16384))
            observations = strict_json(boundary.regular_bytes(directory / 'shared/observations.json', 4096))
            if set(observations) != {'readDenied', 'writeDenied', 'spawnDenied', '127.0.0.1', '::1'} or not all(v is True for v in observations.values()):
                raise ValueError('Hook denial observations differ')
            stage(name, [tools['dart'], protocol_kernel, 'validate', directory, name], input_path=protocol_kernel)
            report[name + 'HookValidated'] = True
        compiled = root / 'compile-engine'
        stage('compile-engine', [tools['aot'], tools['frontend'], '--sdk-root', sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk', '--target=flutter', '--no-link-platform', '--output-dill', compiled / 'engine.dill', source / 'engine.dart'])
        kernel = compiled / 'engine.dill'
        data = boundary.regular_bytes(kernel, boundary.MAX_KERNEL)
        if data[:4] != b'\x90\xab\xcd\xef':
            raise ValueError('Engine kernel')
        kernel.chmod(0o400)
        expected = {'session': secrets.token_hex(24), 'source': FIXTURES['engine.dart'], 'kernel': boundary.digest(data)}
        env.update(SESSION_TOKEN=expected['session'], SOURCE_HASH=expected['source'], KERNEL_HASH=expected['kernel'], SERVER_PORT=str(owned.port))
        broker_path = root / 'broker.json'
        worker = multiprocessing.get_context('fork').Process(target=broker, args=(owned.sockets, broker_path, expected))
        worker.start()
        report['engineDispatched'] = True
        stage('engine', [tools['engine'], '--disable-vm-service', '--enable-software-rendering', '--non-interactive', '--icu-data-file-path=' + str(tools['icu']), kernel], input_path=kernel, timeout=1 if case == 'engine-timeout' else 10, cancel=.2 if case == 'stop' else None, port=owned.port)
        worker.join(3)
        if worker.is_alive():
            raise ValueError('Broker unsettled')
        report['broker'] = strict_json(boundary.regular_bytes(broker_path, 16384))
        if not report['broker']['pass'] or report['broker']['accepted'] != ['IPv4', 'IPv6']:
            raise ValueError('Broker refused')
        if stopped[0]:
            raise ValueError('Supervisor stopped')
        report['pass'] = True
    except (OSError, ValueError) as error:
        report['error'] = str(error)
    finally:
        if worker is not None:
            if worker.is_alive():
                worker.terminate()
            worker.join(2)
            if worker.is_alive():
                worker.kill()
                worker.join(2)
            report['brokerReaped'] = not worker.is_alive()
            if (root / 'broker.json').exists():
                report['broker'] = strict_json(boundary.regular_bytes(root / 'broker.json', 16384))
        report['canaryConnections'] = 0
        if canary is not None:
            for listener in canary.sockets:
                try:
                    connection, _ = listener.accept()
                    connection.close()
                    report['canaryConnections'] += 1
                except BlockingIOError:
                    pass
        for sig, handler in previous.items():
            signal.signal(sig, handler)
        for ports in (owned, canary):
            if ports is not None:
                ports.close()
        report['sourcesPreserved'] = all(boundary.digest(boundary.regular_bytes(Path(p), 1024 * 1024)) == h for p, h in pinned.items())
        report['sentinelPreserved'] = sentinel.read_text() == 'preserved'
        report['toolsPreserved'] = boundary.toolchain(sdk)[3] == tool_hashes and all(boundary.digest(boundary.regular_bytes(Path(p), 256 * 1024 * 1024)) == h for p, h in report.get('hookCompilerHashes', {}).items())
        report['kernelsPreserved'] = all(boundary.digest(boundary.regular_bytes(Path(p), boundary.MAX_KERNEL)) == h for p, h in report.get('hookKernelHashes', {}).items())
        report['pass'] = bool(report['pass'] and report['canaryConnections'] == 0 and report.get('brokerReaped', True) and all(report[k] for k in ('sourcesPreserved', 'sentinelPreserved', 'toolsPreserved', 'kernelsPreserved')))
        stages = list(report['stages'].values())
        last = stages[-1] if stages else {}
        expected = expected_failure(case, report)
        report['adverseCaseObserved'] = bool(expected and not report['pass'] and report['canaryConnections'] == 0 and all(x['groupReaped'] for x in stages)
            and report.get('brokerReaped', True) and all(report[k] for k in ('sourcesPreserved', 'sentinelPreserved', 'toolsPreserved', 'kernelsPreserved')))
        (root / 'report.json').write_text(json.dumps(report, indent=2))
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synthetic-fixture', action='store_true', required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--case', choices=CASES, default='positive')
    args = parser.parse_args()
    result = exercise(args.sdk, args.case)
    print(json.dumps(result))
    raise SystemExit(0 if result['pass'] or result['adverseCaseObserved'] else 1)
