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
    'generate.dart.txt': '030691a13a54a545a43a49c1a4839a3ba7319e36dd3e9a1cd2c66facb0799921',
    'fixed_tests.dart.txt': '3833141c80c893d71344a167a0f6e997c4156b6570170178b6e7136122ff68a0',
    'driver.dart.txt': '1c63a715bd9a23e704bccb89175d6d6faecc92ccf2b71ae4b727573ec7eb28c4',
    'engine.dart.txt': 'a373fb96f3ad88822d6d5b04540fd573a01118a8126b17fb19adea11dccb2e5b',
    'ingress.dart.txt': '83ab9ecfeda1f941db26bf4b2e21ccf01c60b048eeaaaafaeaa3d79202b0d3b4',
}
STOCK_DEVICE_HASH = 'dfeaccb3798dd8e315f8131d74464951c838bc43b3e23442dac9c07bf0c3a82c'
INGRESS_CASES = {
    'oversized-header': 'frame-size', 'fragmented-header': 'frame-format',
    'session-bytes': 'session-bytes', 'session-frames': 'session-frames',
}
POSITIVE_CASES = ('positive', 'generated-positive')
STOP_CASES = ('stop', 'generated-stop')
GENERATED_CASES = ('generated-positive', 'generated-missing-token', 'generated-stop')
FAMILIES = ('IPv4', 'IPv6')
CASES = (
    'positive', 'wrong-token', 'missing-suite', 'wrong-suite', 'wrong-result', 'deadline', 'stop',
    *INGRESS_CASES, *GENERATED_CASES, 'unexpected-extension',
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
    if case in STOP_CASES:
        return (execution['reason'] == 'cancelled' and execution['waitEntered'] is True
                and execution['exitCode'] in (-signal.SIGTERM, -signal.SIGKILL)
                and families is None)
    if (execution['exitCode'] != 0 or execution['reason'] is not None or
            not isinstance(families, list) or not all(isinstance(row, dict) for row in families)):
        return False
    if any(type(row.get('rejected')) is not int or row.get('engineSettled') is not True
           or ('complete' in row and row['complete'] is not True) for row in families):
        return False
    if case in POSITIVE_CASES:
        generated = {'stockOfferDeclined': True} if case in GENERATED_CASES else {}
        return families == [
            dict(family=family, outcomes=OUTCOMES, complete=True,
                 phase='test-run', rejected=0, engineSettled=True, ingressAttached=True, **generated)
            for family in FAMILIES
        ]
    if len(families) != 1:
        return False
    row = families[0]
    if row.get('family') != 'IPv4' or 'complete' in row:
        return False
    observed = (row.get('phase'), row.get('failure'), row.get('outcomes'))
    if case in ('wrong-token', 'generated-missing-token'):
        return (observed == ('device-start', 'token-refused', {}) and
                type(row.get('rejected')) is int and row['rejected'] > 0 and
                row.get('ingressAttached') is False and 'ingressFailure' not in row and
                (case == 'wrong-token' or (row.get('stockOfferDeclined') is False and
                                           type(row.get('engineExitCode')) is int and row['engineExitCode'] == 1)))
    if case == 'unexpected-extension':
        return (observed == ('device-start', 'ingress-refused', {}) and row.get('rejected') == 0 and
                row.get('ingressAttached') is False and row.get('ingressFailure') == 'extensions' and
                row.get('stockOfferDeclined') is False and row.get('wirePeerRefused') is True and
                execution.get('wirePeerReceipt') is True)
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
                    for family in FAMILIES:
                        policy = boundary.profile(
                            sdk, source, config['engineDir'], kernel=config['kernels'][family], port=port,
                        )
                        Path(config['enginePolicies'][family]).write_text(policy)
                    Path(config['continue']).touch(exist_ok=False)
                if waiting.exists():
                    wait_entered = boundary.regular_bytes(waiting, 16) == b'IPv4'
                if stop or (case in STOP_CASES and wait_entered):
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


def compile_fixtures(root, source, sdk, tools, packages, cache, case, report):
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
    policy = boundary.profile(sdk, source, directory)
    policy += f'(allow file-read* (subpath {json.dumps(str(cache))}))\n'
    report['compilation'] = {}
    report['sourceClosures'] = {}
    kernels = {}

    def run(name, command):
        stage = boundary.run_stage(command, directory, stage_environment(directory), policy)
        report['compilation'][name] = stage
        if stage['exitCode'] != 0 or stage['reason'] or not stage['groupReaped']:
            raise ValueError(f'{name} failed')

    def compile_kernel(name, entry, *, flutter=False):
        output = directory / f'{name}.dill'
        depfile = directory / f'{name}.dill.d'
        compiler = (
            [tools['aot'], tools['frontend'], f'--sdk-root={patched_sdk}', '--target=flutter',
             f'--output-dill={output}'] if flutter else
            [tools['aot'], snapshot, f'--platform={vm_platform}', '--no-embed-sources',
             f'--output={output}']
        )
        run(name, [*compiler, '--no-link-platform', f'--packages={packages}',
                   f'--depfile={depfile}', entry])
        data = boundary.regular_bytes(output, boundary.MAX_KERNEL)
        if data[:4] != b'\x90\xab\xcd\xef':
            raise ValueError(f'{name} kernel identity invalid')
        output.chmod(0o400)
        kernels[output] = boundary.digest(data)
        report['sourceClosures'][name] = adapters.trusted_imports(depfile)
        return output

    driver = compile_kernel('driver', source / 'driver.dart')
    generated_sources = {}
    if case in GENERATED_CASES:
        generator = compile_kernel('generator', source / 'generate.dart')
        generator_source = sdk / 'packages/flutter_tools/lib/src/test/flutter_platform.dart'
        if str(generator_source) not in report['sourceClosures']['generator']:
            raise ValueError('Installed bootstrap generator is absent from the compiler closure')
        run('generate', [tools['dart'], f'--packages={packages}', generator, directory,
                         source / 'fixed_tests.dart'])
        engines = {}
        for family in FAMILIES:
            bootstrap = directory / f'bootstrap_{family}.dart'
            data = boundary.regular_bytes(bootstrap, 32768)
            generated_sources[bootstrap] = boundary.digest(data)
            bootstrap.chmod(0o400)
            stage = f'engine-{family}'
            engines[family] = compile_kernel(stage, bootstrap, flutter=True)
            closure = report['sourceClosures'][stage]
            if (closure.get(str(bootstrap)) != generated_sources[bootstrap] or
                    closure.get(str(source / 'fixed_tests.dart')) != report['fixtureHashes']['fixed_tests.dart']):
                raise ValueError('Generated bootstrap or fixed test identity differs in the engine closure')
        report['generatedBootstrapHashes'] = {p.name: h for p, h in generated_sources.items()}
    else:
        engine = compile_kernel('engine', source / 'engine.dart', flutter=True)
        engines = dict.fromkeys(FAMILIES, engine)
    report['kernelHashes'] = {str(k): v for k, v in kernels.items()}
    return driver, engines, kernels, compiler_inputs, generated_sources


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
        driver, engines, kernels, compiler_inputs, generated_sources = compile_fixtures(
            root, source, sdk, tools, packages, cache, case, report,
        )
        engine_dir = root / 'engine'
        engine_dir.mkdir()
        config = {key: str(root / key) for key in ('ready', 'continue', 'result', 'sentinel', 'fonts')}
        Path(config['fonts']).write_text('<fontconfig></fontconfig>')
        sentinel = Path(config['sentinel'])
        sentinel.write_text('preserved')
        canary = boundary.OwnedPorts()
        try:
            config.update(
                kernels={family: str(kernel) for family, kernel in engines.items()},
                enginePolicies={family: str(root / f'engine-{family}.sb') for family in FAMILIES},
                packages=str(packages), engine=str(tools['engine']), icu=str(tools['icu']),
                engineDir=str(engine_dir),
                session=secrets.token_hex(24), canaryPort=str(canary.port), case=case,
                sourceHashes={
                    family: (report['generatedBootstrapHashes'][f'bootstrap_{family}.dart']
                             if case in GENERATED_CASES else report['fixtureHashes']['engine.dart'])
                    for family in FAMILIES
                },
                kernelHashes={family: kernels[kernel] for family, kernel in engines.items()},
            )
            config_path = root / 'driver.json'
            config_path.write_text(json.dumps(config))
            execution = run_driver(
                [tools['dart'], f'--packages={packages}', driver, config_path],
                root, config, sdk, source, case,
            )
            if case in INGRESS_CASES or case == 'unexpected-extension':
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
        report['enginePolicyHashes'] = {
            family: boundary.digest(boundary.regular_bytes(policy, 4096))
            for family, policy in config['enginePolicies'].items() if Path(policy).exists()
        }
        result_path = Path(config['result'])
        families = design.strict_json(boundary.regular_bytes(result_path, 16384)) if result_path.exists() else None
        report['families'] = families
        report['inputsPreserved'] = (
            read_fixtures(tools_dir) == fixture_bytes
            and boundary.regular_bytes(packages, 1024 * 1024) == package_config
            and boundary.toolchain(sdk)[3] == tool_hashes
            and all(boundary.digest(boundary.regular_bytes(p, 256 * 1024 * 1024)) == h
                    for p, h in compiler_inputs.items())
            and all(boundary.digest(boundary.regular_bytes(p, 32768)) == h
                    for p, h in generated_sources.items())
            and all(boundary.digest(boundary.regular_bytes(p, boundary.MAX_KERNEL)) == h
                    for p, h in kernels.items())
            and all(boundary.digest(boundary.regular_bytes(p, 2 * 1024 * 1024)) == h
                    for closure in report['sourceClosures'].values() for p, h in closure.items())
            and boundary.regular_bytes(sentinel, 32) == b'preserved'
        )
        accepted = (
            report['inputsPreserved'] and execution['groupReaped']
            and execution['port'] is not None and set(report['enginePolicyHashes']) == set(FAMILIES)
            and report['canaryConnections'] == 0 and result_matches(case, families, execution)
        )
        report['pass'] = case in POSITIVE_CASES and accepted
        report['adverseCaseObserved'] = case not in POSITIVE_CASES and accepted
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
