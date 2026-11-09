# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Run named, authored stock test events through the isolated Flutter tester."""

import argparse
import json
import os
from pathlib import Path
import secrets
import selectors
import signal
import subprocess
import sys
import tempfile
import time

import f12_runner_adapters as adapters
import f12_runner_boundary as boundary
import f12_supervisor_design as design

FIXTURES = {
    'driver.dart.txt': '28a77b3e24766f0e4fc2f3bd9aabcd923d4e4f4871895141686b5623d288ccea',
    'engine.dart.txt': '71e75ba5c98ceb51db18e1b3b0bbd1f54d001683d23ea113455886710a103e23',
    'ingress.dart.txt': '0b3fccd7851df9e8bb0da2fb1331552053f0b45e4c914beb53e11790766bf3c1',
}
STOCK_DEVICE_HASH = '4922efe655e01cc4c3574d274293c588ffdc3fc1018976038624085c76b3d8d4'
INGRESS_CASES = {
    'oversized-header': 'frame-size', 'fragmented-header': 'frame-format',
    'session-bytes': 'session-bytes', 'session-frames': 'session-frames',
}
CASES = (
    'positive', 'wrong-token', 'missing-suite', 'wrong-suite', 'wrong-result', 'deadline', 'stop',
    *INGRESS_CASES,
)
OUTCOMES = {
    'fixture renders in confinement': 'success',
    'fixture deliberate failure': 'failure',
}
TEST_PACKAGES = {'test_api': '0.7.12', 'test_core': '0.6.18'}


def read_fixtures(tools_dir):
    paths = {
        name: (tools_dir / 'f12_stock_test_fixtures' / name, digest)
        for name, digest in FIXTURES.items()
    }
    paths['stock_device.dart.txt'] = (
        tools_dir / 'f12_adapter_fixtures/driver.dart.txt', STOCK_DEVICE_HASH,
    )
    fixtures = {}
    for name, (path, expected) in paths.items():
        data = boundary.regular_bytes(path, 32768)
        if boundary.digest(data) != expected:
            raise ValueError(f'Fixed fixture identity differs: {name}')
        fixtures[name.removesuffix('.txt')] = data
    return fixtures


def read_port(path):
    value = design.strict_json(boundary.regular_bytes(path, 256))
    if (not isinstance(value, dict) or set(value) != {'port'} or
            type(value['port']) is not int or not 1 <= value['port'] <= 65535):
        raise ValueError('Invalid retained-port receipt')
    return value['port']


def result_matches(case, families, execution):
    """Refuse incomplete or contradictory observations for each named case."""
    if case == 'stop':
        return (execution['reason'] == 'cancelled' and execution['waitEntered'] is True
                and execution['exitCode'] in (-signal.SIGTERM, -signal.SIGKILL)
                and families is None)
    if (execution['exitCode'] != 0 or execution['reason'] is not None or
            not isinstance(families, list) or not all(isinstance(row, dict) for row in families)):
        return False
    if any(type(row.get('rejected')) is not int or row.get('engineSettled') is not True
           or ('complete' in row and row['complete'] is not True) for row in families):
        return False
    if case == 'positive':
        return families == [
            dict(family=family, outcomes=OUTCOMES, complete=True,
                 phase='test-run', rejected=0, engineSettled=True, ingressAttached=True)
            for family in ('IPv4', 'IPv6')
        ]
    if len(families) != 1:
        return False
    row = families[0]
    if row.get('family') != 'IPv4' or 'complete' in row:
        return False
    observed = (row.get('phase'), row.get('failure'), row.get('outcomes'))
    if case == 'wrong-token':
        return (observed == ('device-start', 'token-refused', {}) and
                type(row.get('rejected')) is int and row['rejected'] > 0 and
                row.get('ingressAttached') is False and 'ingressFailure' not in row)
    if row.get('rejected') != 0 or row.get('ingressAttached') is not True:
        return False
    if case in INGRESS_CASES:
        return (observed == ('suite-load', 'ingress-refused', {}) and
                row.get('ingressFailure') == INGRESS_CASES[case] and
                row.get('wirePeerClosed') is True and execution.get('wirePeerReceipt') is True)
    if 'ingressFailure' in row:
        return False
    if case == 'missing-suite':
        return observed == ('suite-load', 'suite-error', {})
    if case == 'wrong-suite':
        return observed == ('suite-load', 'suite-names', {})
    if case == 'wrong-result':
        return observed == ('test-run', 'test-result', dict.fromkeys(OUTCOMES, 'success'))
    if case == 'deadline':
        return observed == ('test-run', 'deadline', OUTCOMES) and execution['waitEntered']
    return False


def run_driver(argv, root, config, sdk, source, case):
    """Own and settle the fixed driver and all of its confined descendants."""
    ready = Path(config['ready'])
    waiting = Path(config['engineDir']) / 'waiting'
    output = bytearray()
    port = None
    wait_entered = False
    output_overflow = False
    reason = None
    stop = False

    def request_stop(*_):
        nonlocal stop
        stop = True

    def signal_group(sig):
        try:
            os.killpg(process.pid, sig)
            return True
        except ProcessLookupError:
            return False

    previous = {sig: signal.signal(sig, request_stop) for sig in (signal.SIGTERM, signal.SIGINT)}
    process = None
    started = time.monotonic()
    try:
        process = subprocess.Popen(
            argv, cwd=root, env=stage_environment(root), stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, close_fds=True,
            start_new_session=True, preexec_fn=boundary.limits,
        )
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)

            def capture(timeout):
                nonlocal output_overflow
                for key, _ in selector.select(timeout):
                    chunk = os.read(key.fd, 4096)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    room = boundary.OUTPUT_LIMIT - len(output)
                    output.extend(chunk[:room])
                    output_overflow |= len(chunk) > room

            while process.poll() is None:
                if ready.exists() and port is None:
                    port = read_port(ready)
                    policy = boundary.profile(
                        sdk, source, config['engineDir'], kernel=config['kernel'], port=port,
                    )
                    Path(config['enginePolicy']).write_text(policy)
                    Path(config['continue']).touch(exist_ok=False)
                if waiting.exists():
                    wait_entered = boundary.regular_bytes(waiting, 16) == b'IPv4'
                if stop or (case == 'stop' and wait_entered):
                    reason = 'cancelled'
                elif output_overflow:
                    reason = 'outputLimit'
                elif time.monotonic() - started >= 18:
                    reason = 'driver-deadline'
                if reason:
                    break
                capture(.02)
            if process.poll() is None:
                signal_group(signal.SIGTERM)
            try:
                process.wait(timeout=.4)
            except subprocess.TimeoutExpired:
                signal_group(signal.SIGKILL)
                process.wait(timeout=2)
            signal_group(signal.SIGKILL)
            drain_until = time.monotonic() + .5
            while selector.get_map() and time.monotonic() < drain_until:
                capture(.02)
            if selector.get_map():
                reason = 'unsettledOutput'
            if output_overflow:
                reason = 'outputLimit'
        return {
            'exitCode': process.returncode, 'reason': reason, 'port': port,
            'waitEntered': wait_entered, 'output': output.decode(errors='replace'),
            'groupReaped': not signal_group(0), 'argv': list(map(str, argv)),
            'elapsedSeconds': time.monotonic() - started,
        }
    finally:
        if process is not None:
            signal_group(signal.SIGKILL)
            process.wait(timeout=2)
            process.stdout.close()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def stage_environment(directory):
    return {'PATH': '/usr/bin:/bin', 'HOME': str(directory), 'TMPDIR': str(directory) + '/'}


def compile_fixtures(root, source, sdk, tools, packages, cache, report):
    directory = root / 'compile'
    directory.mkdir()
    snapshot = sdk / 'bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot'
    vm_platform = sdk / 'bin/cache/dart-sdk/lib/_internal/vm_platform_product.dill'
    patched_sdk = sdk / 'bin/cache/artifacts/engine/common/flutter_patched_sdk'
    compiler_inputs = {
        path: boundary.digest(boundary.regular_bytes(path, 256 * 1024 * 1024))
        for path in (snapshot, vm_platform)
    }
    report['additionalCompilerHashes'] = {str(k): v for k, v in compiler_inputs.items()}
    commands = {
        'driver': [tools['aot'], snapshot, f'--platform={vm_platform}',
                   '--no-link-platform', '--no-embed-sources', f'--packages={packages}',
                   f'--output={directory}/driver.dill', f'--depfile={directory}/driver.dill.d',
                   source / 'driver.dart'],
        'engine': [tools['aot'], tools['frontend'], f'--sdk-root={patched_sdk}',
                   '--target=flutter', '--no-link-platform', f'--packages={packages}',
                   f'--output-dill={directory}/engine.dill', f'--depfile={directory}/engine.dill.d',
                   source / 'engine.dart'],
    }
    policy = boundary.profile(sdk, source, directory)
    policy += f'(allow file-read* (subpath {json.dumps(str(cache))}))\n'
    report['compilation'] = {}
    report['sourceClosures'] = {}
    kernels = {}
    for name, command in commands.items():
        stage = boundary.run_stage(command, directory, stage_environment(directory), policy)
        report['compilation'][name] = stage
        if stage['exitCode'] != 0 or stage['reason'] or not stage['groupReaped']:
            raise ValueError(f'{name} compilation failed')
        kernel = directory / f'{name}.dill'
        data = boundary.regular_bytes(kernel, boundary.MAX_KERNEL)
        if data[:4] != b'\x90\xab\xcd\xef':
            raise ValueError(f'{name} kernel identity invalid')
        kernel.chmod(0o400)
        kernels[kernel] = boundary.digest(data)
        report['sourceClosures'][name] = adapters.trusted_imports(Path(str(kernel) + '.d'))
    report['kernelHashes'] = {str(k): v for k, v in kernels.items()}
    return directory, kernels, compiler_inputs


def exercise(sdk_path, case):
    if case not in CASES or sys.platform != 'darwin':
        raise ValueError('This fixed fixture requires a known case and macOS')
    sdk, version, tools, tool_hashes = boundary.toolchain(sdk_path)
    tools_dir = Path(__file__).resolve().parent
    fixture_bytes = read_fixtures(tools_dir)
    packages = sdk / 'packages/flutter_tools/.dart_tool/package_config.json'
    package_config = boundary.regular_bytes(packages, 1024 * 1024)
    cache = Path.home() / '.pub-cache'
    declarations = design.strict_json(package_config)['packages']
    for name, version_number in TEST_PACKAGES.items():
        expected = (cache / 'hosted/pub.dev' / f'{name}-{version_number}').as_uri()
        declared = [entry for entry in declarations if entry['name'] == name]
        if len(declared) != 1 or declared[0]['rootUri'].rstrip('/') != expected:
            raise ValueError(f'Unsupported installed {name} package')
    root = Path(tempfile.mkdtemp(prefix='asg-f12-stock-events-')).resolve()
    report = {
        'kind': 'fixed-stock-test-events-only', 'candidateExecutionEnabled': False,
        'case': case, 'run': str(root), 'sdkVersion': version, 'toolHashes': tool_hashes,
        'packageVersions': TEST_PACKAGES, 'packageConfigHash': boundary.digest(package_config),
        'helperHashes': {
            module.__name__: boundary.digest(boundary.regular_bytes(module.__file__, 128 * 1024))
            for module in (sys.modules[__name__], adapters, boundary, design)
        },
        'fixtureHashes': {k: boundary.digest(v) for k, v in fixture_bytes.items()},
        'pass': False, 'adverseCaseObserved': False,
    }
    try:
        source = root / 'source'
        source.mkdir()
        for name, data in fixture_bytes.items():
            path = source / name
            path.write_bytes(data)
            path.chmod(0o400)
        compiled, kernels, compiler_inputs = compile_fixtures(root, source, sdk, tools, packages, cache, report)
        engine_dir = root / 'engine'
        engine_dir.mkdir()
        config = {key: str(root / key) for key in ('ready', 'continue', 'result', 'sentinel', 'fonts')}
        Path(config['fonts']).write_text('<fontconfig></fontconfig>')
        sentinel = Path(config['sentinel'])
        sentinel.write_text('preserved')
        canary = boundary.OwnedPorts()
        try:
            engine = compiled / 'engine.dill'
            config.update(
                kernel=str(engine), packages=str(packages), engine=str(tools['engine']),
                icu=str(tools['icu']), enginePolicy=str(root / 'engine.sb'), engineDir=str(engine_dir),
                session=secrets.token_hex(24), canaryPort=str(canary.port), case=case,
                sourceHash=report['fixtureHashes']['engine.dart'], kernelHash=kernels[engine],
            )
            config_path = root / 'driver.json'
            config_path.write_text(json.dumps(config))
            execution = run_driver(
                [tools['dart'], f'--packages={packages}', compiled / 'driver.dill', config_path],
                root, config, sdk, source, case,
            )
            if case in INGRESS_CASES:
                peer_receipt = engine_dir / 'wire-peer-closed'
                execution['wirePeerReceipt'] = (peer_receipt.exists() and
                                                boundary.regular_bytes(peer_receipt, 32) == case.encode())
            report['execution'] = execution
            report['canaryConnections'] = 0
            for listener in canary.sockets:
                try:
                    connection, _ = listener.accept()
                except BlockingIOError:
                    continue
                connection.close()
                report['canaryConnections'] += 1
        finally:
            canary.close()
        if Path(config['enginePolicy']).exists():
            report['enginePolicyHash'] = boundary.digest(boundary.regular_bytes(config['enginePolicy'], 4096))
        result_path = Path(config['result'])
        families = design.strict_json(boundary.regular_bytes(result_path, 16384)) if result_path.exists() else None
        report['families'] = families
        report['inputsPreserved'] = (
            read_fixtures(tools_dir) == fixture_bytes
            and boundary.regular_bytes(packages, 1024 * 1024) == package_config
            and boundary.toolchain(sdk)[3] == tool_hashes
            and all(boundary.digest(boundary.regular_bytes(p, 256 * 1024 * 1024)) == h
                    for p, h in compiler_inputs.items())
            and all(boundary.digest(boundary.regular_bytes(p, boundary.MAX_KERNEL)) == h
                    for p, h in kernels.items())
            and all(boundary.digest(boundary.regular_bytes(p, 2 * 1024 * 1024)) == h
                    for closure in report['sourceClosures'].values() for p, h in closure.items())
            and boundary.regular_bytes(sentinel, 32) == b'preserved'
        )
        accepted = (
            report['inputsPreserved'] and execution['groupReaped']
            and execution['port'] is not None and 'enginePolicyHash' in report
            and report['canaryConnections'] == 0 and result_matches(case, families, execution)
        )
        report['pass'] = case == 'positive' and accepted
        report['adverseCaseObserved'] = case != 'positive' and accepted
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        report['error'] = str(error)
    (root / 'report.json').write_text(json.dumps(report, indent=2))
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--synthetic-fixture', action='store_true', required=True)
    parser.add_argument('--sdk', required=True)
    parser.add_argument('--case', choices=CASES, default='positive')
    args = parser.parse_args(argv)
    try:
        report = exercise(args.sdk, args.case)
    except (OSError, ValueError, KeyError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps({
        'case': args.case, 'pass': report['pass'],
        'adverseCaseObserved': report['adverseCaseObserved'],
        'report': str(Path(report['run']) / 'report.json'),
    }))
    return 0 if report['pass'] or report['adverseCaseObserved'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
