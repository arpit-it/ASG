# SPDX-License-Identifier: MPL-2.0
# Copyright 2026 Arpit Sinha
"""Authored fixture adapters for installed hooks_runner and stock Flutter device.

No candidate/source/command argument is accepted. Trusted orchestrators use fixed
inputs; every actual hook/compiler/engine dispatch receives a separate policy.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import unquote, urlparse

import f12_runner_boundary as boundary
import f12_supervisor_design as design

FIXTURES = {'hook.dart.txt': 'eec1291ba1654048db17e10f94cf5e15954900307dac0dba854392504cbc3441', 'engine.dart.txt': '24605d25606cd2dc144b44dfff415f189e6eca3f984c085153c71f3974946c2d', 'driver.dart.txt': '4922efe655e01cc4c3574d274293c588ffdc3fc1018976038624085c76b3d8d4'}
CASES = ('positive', 'hook-failure', 'hook-timeout', 'hook-output', 'hook-overflow', 'wrong-token', 'oversized-message', 'malformed-message', 'engine-timeout', 'stop')


def beneath(path, root):
    path, root = Path(path), Path(root)
    if not path.is_absolute() or path.resolve() != path or root not in path.parents:
        raise ValueError('Unadmitted path')
    return path


def admit(arguments, config, cwd):
    """Only unchanged hooks_runner 1.5.0 compiler and hook invocation shapes."""
    source, cache, packages = map(Path, (config['source'], config['cache'], config['packages']))
    if len(arguments) == 6 and arguments[:2] == ['compile', 'kernel']:
        if arguments[2] != '--packages=' + str(packages) or Path(cwd) != Path(config['project']):
            raise ValueError('Unadmitted compile context')
        output = beneath(arguments[3].removeprefix('--output='), cache)
        depfile = beneath(arguments[4].removeprefix('--depfile='), cache)
        script = Path(arguments[5])
        if (not arguments[3].startswith('--output=') or not arguments[4].startswith('--depfile=')
                or script not in [source / p / 'hook' / (h + '.dart') for p in ('fixture_a', 'fixture_b') for h in ('build', 'link')]
                or output.parent != depfile.parent or output.suffix != '.dill'):
            raise ValueError('Unadmitted compile command')
        relative=output.relative_to(cache).parts
        if (len(relative)!=3 or relative[0]!=script.relative_to(source).parts[0] or not re.fullmatch(r'[a-f0-9]{10}',relative[1]) or relative[2]!='hook.dill' or depfile!=Path(str(output)+'.d')):
            raise ValueError('Unadmitted package cache destination')
        return 'compile', script, output, depfile
    if len(arguments) == 3 and arguments[0] == '--packages=' + str(packages) and arguments[2].startswith('--config='):
        kernel, input_path = beneath(arguments[1], cache), beneath(arguments[2][9:], cache)
        value = design.strict_json(boundary.regular_bytes(input_path, 16384))
        package = value.get('package_name')
        if (package not in ('fixture_a', 'fixture_b') or Path(cwd) != source / package
                or value.get('package_root') != str(source / package) + '/' or kernel.suffix != '.dill'):
            raise ValueError('Unadmitted hook context')
        return 'hook', input_path, kernel, value
    raise ValueError('Unadmitted hooks_runner invocation')


def dispatch(config, arguments):
    """Called only by a generated manifest-bound executable, not a public CLI."""
    record = {'pass': False}
    cancelled = threading.Event()
    old_handlers = {s: signal.signal(s, lambda *_: cancelled.set()) for s in (signal.SIGTERM, signal.SIGINT)}
    try:
        kind, first, second, extra = admit(arguments, config, os.getcwd())
        sdk, source = Path(config['sdk']), Path(config['source'])
        if boundary.toolchain(sdk)[3] != config['tools']:
            raise ValueError('Tool changed')
        for p,h in config['compilerTools'].items():
            if boundary.digest(boundary.regular_bytes(p,256*1024*1024)) != h:raise ValueError('Compiler tool changed')
        for p, h in config['pinned'].items():
            if boundary.digest(boundary.regular_bytes(p, 1024 * 1024)) != h:
                raise ValueError('Source changed')
        if kind == 'compile':
            target, depfile = second, extra
            target.parent.mkdir(parents=True, exist_ok=True)
            policy = boundary.profile(sdk, source, target.parent)
            command = [sdk / 'bin/cache/dart-sdk/bin/dartaotruntime', sdk / 'bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot', '--platform=' + str(sdk / 'bin/cache/dart-sdk/lib/_internal/vm_platform_product.dill'), '--packages=' + config['packages'], '--output=' + str(target), '--depfile=' + str(depfile), first]
            writable = target.parent
        else:
            prior = [json.loads(x) for x in Path(config['transcript']).read_text().splitlines()]
            matching = [x for x in prior if x.get('kind') == 'compile' and x.get('kernel') == str(second) and x.get('pass')]
            if len(matching) != 1 or boundary.digest(boundary.regular_bytes(second, boundary.MAX_KERNEL)) != matching[0]['kernelHash']:
                raise ValueError('Unadmitted hook kernel')
            hook_stage = 'link' if matching[0]['script'].endswith('/link.dart') else 'build'
            value = extra
            if first.parent != second.parent or first.name != 'input.json' or value.get('out_file') != str(first.parent/'output.json') or Path(value.get('out_dir_shared','')) != Path(config['cache'])/'shared'/value['package_name']/hook_stage or Path(matching[0]['script']).relative_to(source).parts[0] != value['package_name']:
                raise ValueError('Unadmitted hook output scope')
            output = beneath(value['out_file'], Path(config['cache']))
            shared = beneath(str(Path(value['out_dir_shared'])), Path(config['cache']))
            shared.mkdir(parents=True, exist_ok=True)
            writable = output.parent
            policy = boundary.profile(sdk, source, writable, kernel=second)
            policy += '(allow file-write* (subpath ' + json.dumps(str(shared)) + '))\n'
            policy += '(allow file-read* (literal ' + json.dumps(str(first)) + ') (subpath ' + json.dumps(str(shared)) + '))\n'
            command = [sdk / 'bin/cache/dart-sdk/bin/dart', *arguments]
        policy += '(allow file-read* (literal ' + json.dumps(config['packages']) + '))\n'
        policy_path = writable / 'adapter.sb'
        policy_path.write_text(policy)
        before = boundary.digest(boundary.regular_bytes(first, 16384))
        env = {'PATH': '/usr/bin:/bin', 'HOME': str(writable), 'TMPDIR': str(writable) + '/', 'CASE': config['case'], 'HOOK_STAGE': hook_stage if kind == 'hook' else 'compile', 'SENTINEL': config['sentinel'], 'PORT': str(json.loads(Path(config['ready']).read_text())['port'])}
        # Inherit the owned trusted orchestrator group. Never create another group
        # that could outlive the parent deadline/Stop cleanup.
        child = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(policy_path), *map(str, command)], cwd=writable if kind == 'compile' else source / value['package_name'], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, close_fds=True, preexec_fn=boundary.limits)
        captured = bytearray()
        overflow = threading.Event()
        def collect():
            while True:
                part = child.stdout.read1(4096)
                if not part:
                    return
                remaining = boundary.OUTPUT_LIMIT - len(captured)
                captured.extend(part[:remaining])
                if len(part) > remaining:
                    overflow.set()
        reader = threading.Thread(target=collect, daemon=True)
        reader.start()
        started = time.monotonic()
        deadline = 1 if config['case'] == 'hook-timeout' and kind == 'hook' else 20
        try:
            while child.poll() is None:
                if cancelled.is_set():
                    record['reason'] = 'cancelled'
                    break
                if overflow.is_set():
                    record['reason'] = 'outputLimit'
                    break
                if time.monotonic() - started >= deadline:
                    record['reason'] = 'hook-deadline' if kind == 'hook' else 'compile-deadline'
                    break
                time.sleep(.02)
            if child.poll() is None:
                child.kill()
            child.wait(timeout=2)
            reader.join(timeout=2)
            if reader.is_alive():
                raise ValueError('Unsettled child output')
            data = bytes(captured)
            if overflow.is_set():
                record['reason'] = 'outputLimit'
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=2)
            child.stdout.close()
        record.update(kind=kind, command=list(map(str, command)), exitCode=child.returncode, output=data.decode('utf8','replace'), profileSha256=boundary.digest(policy.encode()))
        if boundary.digest(boundary.regular_bytes(first, 16384)) != before:
            raise ValueError('Hook input changed')
        if child.returncode != 0 or record.get('reason'):
            raise ValueError('Confined child failed')
        if kind == 'compile':
            if boundary.regular_bytes(second, boundary.MAX_KERNEL)[:4] != b'\x90\xab\xcd\xef':
                raise ValueError('Kernel invalid')
            record['script'] = str(first)
            record['kernel'] = str(second)
            record['kernelHash'] = boundary.digest(boundary.regular_bytes(second, boundary.MAX_KERNEL))
        else:
            design.hook_output(output)
            observed = design.strict_json(boundary.regular_bytes(shared / (env['HOOK_STAGE'] + '.json'), 4096))
            if set(observed) != {'read','write','fork','127.0.0.1','::1'} or not all(v is True for v in observed.values()):
                raise ValueError('Hook denials failed')
            record.update(package=value['package_name'], hook=env['HOOK_STAGE'])
        record['pass'] = True
    except (ValueError, OSError, KeyError) as error:
        record['error'] = str(error)
    with open(config['transcript'], 'a') as stream:
        stream.write(json.dumps(record) + '\n')
    for sig,handler in old_handlers.items():signal.signal(sig,handler)
    return 0 if record['pass'] else 2


def trusted_imports(depfile):
    """Hash the compiler-reported actual trusted source dependency closure."""
    text = boundary.regular_bytes(depfile, 1024 * 1024).decode('utf8')
    _, dependencies = text.split(': ', 1)
    observed, size = {}, 0
    for value in shlex.split(dependencies):
        path = Path(value)
        data = boundary.regular_bytes(path, 2 * 1024 * 1024)
        size += len(data)
        if len(observed) >= 3000 or size > 40 * 1024 * 1024:
            raise ValueError('Trusted import closure bound')
        observed[str(path)] = boundary.digest(data)
    if not observed:
        raise ValueError('Empty compiler source closure')
    return observed


def exercise(sdk_path, case):
    if case not in CASES:
        raise ValueError('Unknown fixture case')
    sdk, version, tools, tool_hashes = boundary.toolchain(sdk_path)
    root = Path(tempfile.mkdtemp(prefix='asg-f12-adapters-')).resolve();root.chmod(0o700)
    source = root / 'source';source.mkdir(mode=0o700)
    project = root / 'project';project.mkdir(mode=0o700)
    cache = project / '.dart_tool/hooks_runner';cache.mkdir(parents=True)
    report = {'kind':'fixed-real-adapters-only','candidateExecutionEnabled':False,'case':case,'run':str(root),'helperSha256':boundary.digest(Path(__file__).read_bytes()),'helperDependencies':{str(Path(module.__file__).resolve()):boundary.digest(Path(module.__file__).read_bytes()) for module in [boundary,design]},'sdkVersion':version,'toolHashes':tool_hashes,'pass':False}
    fixture_root = Path(__file__).parent / 'f12_adapter_fixtures'
    fixed = {name:boundary.regular_bytes(fixture_root / name,32768) for name in FIXTURES}
    if any(boundary.digest(data)!=FIXTURES[name] for name,data in fixed.items()):raise ValueError('Fixture identity')
    report['fixtureHashes'] = FIXTURES
    # Hook import closure copied read-only; trusted orchestrator compiles against
    # the owner-installed SDK's package config, not any package-controlled source.
    packages, closure = design.dependencies(sdk, source)
    package_json = json.loads(packages.read_text())
    packages.unlink()
    packages = project / '.dart_tool/package_config.json'
    for package in ['fixture_a','fixture_b']:
        p = source / package / 'hook';p.mkdir(parents=True)
        for hook in ['build','link']:(p / (hook+'.dart')).write_bytes(fixed['hook.dart.txt'])
        (p.parent/'pubspec.yaml').write_text('name: '+package+'\nversion: 1.0.0\ndependencies:\n  hooks: any\n'+('  fixture_b: any\n' if package=='fixture_a' else ''))
        package_json['packages'].append({'name':package,'rootUri':str(p.parent)+'/', 'packageUri':'lib/','languageVersion':'3.10'})
    packages.write_text(json.dumps(package_json));packages.chmod(0o400)
    graph = packages.parent/'package_graph.json';graph.write_text(json.dumps({'packages':[{'name':'fixture_a','dependencies':['fixture_b','hooks']},{'name':'fixture_b','dependencies':['hooks']},{'name':'hooks','dependencies':[]}]}))
    for name in ['driver','engine']:(source/(name+'.dart')).write_bytes(fixed[name+'.dart.txt'])
    sentinel=root/'sentinel';sentinel.write_text('preserved')
    pinned={str(p):boundary.digest(boundary.regular_bytes(p,1024*1024)) for p in source.rglob('*') if p.is_file()}
    pinned.update({str(p):boundary.digest(boundary.regular_bytes(p,1024*1024)) for p in [packages,graph]})
    report['installedHookPackageHashes'] = closure
    report['trustedAdapterSourceHashes']={str(p):boundary.digest(boundary.regular_bytes(p,1024*1024)) for p in [sdk/'packages/flutter_tools/.dart_tool/package_config.json',Path.home()/'.pub-cache/hosted/pub.dev/hooks_runner-1.5.0/pubspec.yaml']}
    if not re.search(rb'^version: 1\.5\.0$',boundary.regular_bytes(Path.home()/'.pub-cache/hosted/pub.dev/hooks_runner-1.5.0/pubspec.yaml',65536),re.M):raise ValueError('Unsupported hooks_runner')
    pinned.update(report['trustedAdapterSourceHashes'])
    pinned.update(report['helperDependencies'])
    report['compilerToolHashes']={str(p):boundary.digest(boundary.regular_bytes(p,256*1024*1024)) for p in [sdk/'bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot',sdk/'bin/cache/dart-sdk/lib/_internal/vm_platform_product.dill']}
    manifest={'compilerTools':report['compilerToolHashes'],'sdk':str(sdk),'source':str(source),'project':str(project),'cache':str(cache),'packages':str(packages),'tools':tool_hashes,'pinned':pinned,'case':case,'sentinel':str(sentinel),'ready':str(root/'ready.json'),'transcript':str(root/'dispatch.jsonl')}
    shim=root/'bin/dart';shim.parent.mkdir();shim.write_text('#!/usr/bin/python3\nimport sys\nsys.path.insert(0,'+repr(str(Path(__file__).resolve().parent))+')\nimport f12_runner_adapters as a\nraise SystemExit(a.dispatch('+repr(manifest)+',sys.argv[1:]))\n');shim.chmod(0o700)
    # hooks_runner resolves ../version relative to dartExecutable.
    (root/'version').write_text(version['dartSdkVersion'])
    compile_dir=root/'compile';compile_dir.mkdir()
    extra_read= '(allow file-read* (subpath '+json.dumps(str(Path.home()/'.pub-cache'))+'))\n'
    trusted_config=sdk/'packages/flutter_tools/.dart_tool/package_config.json'
    compile_commands=[('driver',[tools['aot'],sdk/'bin/cache/dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot','--platform='+str(sdk/'bin/cache/dart-sdk/lib/_internal/vm_platform_product.dill'),'--packages='+str(trusted_config),'--output='+str(compile_dir/'driver.dill'),'--depfile='+str(compile_dir/'driver.dill.d'),source/'driver.dart']),('engine',[tools['aot'],tools['frontend'],'--sdk-root='+str(sdk/'bin/cache/artifacts/engine/common/flutter_patched_sdk'),'--target=flutter','--no-link-platform','--output-dill='+str(compile_dir/'engine.dill'),source/'engine.dart'])]
    report['compilation']={}
    for name,command in compile_commands:
        result=boundary.run_stage(command,compile_dir,{'PATH':'/usr/bin:/bin','HOME':str(compile_dir),'TMPDIR':str(compile_dir)+'/'},boundary.profile(sdk,source,compile_dir)+extra_read)
        report['compilation'][name]=result
        if result['exitCode'] or result['reason'] or not result['groupReaped']:
            report['error']='Adapter compilation failed';(root/'report.json').write_text(json.dumps(report));return report
    report['trustedAdapterSourceHashes'].update(trusted_imports(compile_dir/'driver.dill.d'))
    pinned.update(report['trustedAdapterSourceHashes'])
    shim.write_text('#!/usr/bin/python3\nimport sys\nsys.path.insert(0,'+repr(str(Path(__file__).resolve().parent))+')\nimport f12_runner_adapters as a\nraise SystemExit(a.dispatch('+repr(manifest)+',sys.argv[1:]))\n')
    engine_dir=root/'engine';engine_dir.mkdir();fonts=root/'fonts.conf';fonts.write_text('<fontconfig></fontconfig>')
    kernel_hashes={str(compile_dir/(name+'.dill')):boundary.digest(boundary.regular_bytes(compile_dir/(name+'.dill'),boundary.MAX_KERNEL)) for name in ['driver','engine']}
    for p in kernel_hashes:Path(p).chmod(0o400)
    report['adapterKernelHashes']=kernel_hashes
    canary=boundary.OwnedPorts()
    report['canaryPort']=canary.port
    config={'sentinel':str(sentinel),'canaryPort':str(canary.port),'case':case,'engine':str(tools['engine']),'icu':str(tools['icu']),'kernel':str(compile_dir/'engine.dill'),'packages':str(packages),'sourceHash':FIXTURES['engine.dart.txt'],'kernelHash':boundary.digest(boundary.regular_bytes(compile_dir/'engine.dill',boundary.MAX_KERNEL)),'enginePolicy':str(root/'engine.sb'),'engineDir':str(engine_dir),'session':secrets.token_hex(24),'ready':str(root/'ready.json'),'continue':str(root/'continue'),'result':str(root/'result.json'),'shim':str(shim),'fonts':str(fonts),'active':str(root/'active')}
    config_path=root/'driver.json';config_path.write_text(json.dumps(config))
    output=bytearray(); overflow=threading.Event();stopped=threading.Event();previous={s:signal.signal(s,lambda *_:stopped.set()) for s in [signal.SIGTERM,signal.SIGINT]}
    process=None;started=time.monotonic();reason=None
    try:
        # Fixed trusted orchestrator. It does not import package hook entrypoints;
        # real hooks_runner dispatches only through the manifest-bound shim.
        process=subprocess.Popen([tools['dart'],'--packages='+str(trusted_config),compile_dir/'driver.dill',config_path],cwd=root,env={'PATH':'/usr/bin:/bin','HOME':str(root),'TMPDIR':str(root)+'/'},stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,start_new_session=True,preexec_fn=boundary.limits,close_fds=True)
        def read():
            while True:
                b=process.stdout.read1(4096)
                if not b:return
                remaining=65536-len(output);output.extend(b[:remaining])
                if len(b)>remaining:overflow.set()
        thread=threading.Thread(target=read,daemon=True);thread.start();port=None;active_at=None
        while process.poll() is None:
            if port is None and Path(config['ready']).exists():
                port=json.loads(Path(config['ready']).read_text())['port'];report['port']=port
                Path(config['enginePolicy']).write_text(boundary.profile(sdk,source,engine_dir,kernel=compile_dir/'engine.dill',port=port))
                Path(config['continue']).touch()
            if Path(config['active']).exists() and active_at is None:active_at=time.monotonic()
            if stopped.is_set() or (case=='stop' and active_at and time.monotonic()-active_at>.2):reason='cancelled'
            elif overflow.is_set():reason='outputLimit'
            elif time.monotonic()-started>30:reason='deadline'
            if reason:break
            time.sleep(.02)
        if process.poll() is None:
            if active_at is not None:os.kill(process.pid,signal.SIGTERM)
            else:os.killpg(process.pid,signal.SIGTERM)
        try:process.wait(timeout=.4)
        except subprocess.TimeoutExpired:os.killpg(process.pid,signal.SIGKILL);process.wait(timeout=2)
        try:os.killpg(process.pid,signal.SIGKILL)
        except ProcessLookupError:pass
        thread.join(timeout=2)
        try:os.killpg(process.pid,0);reaped=False
        except ProcessLookupError:reaped=True
        report.update(exitCode=process.returncode,reason=reason,groupReaped=reaped,output=output.decode('utf8','replace'),elapsedSeconds=time.monotonic()-started)
        if Path(config['result']).exists():report['adapter']=design.strict_json(boundary.regular_bytes(config['result'],16384))
        records=[json.loads(x) for x in Path(manifest['transcript']).read_text().splitlines()] if Path(manifest['transcript']).exists() else []
        report['dispatch']=records
        report['kernelsPreserved']=all(boundary.digest(boundary.regular_bytes(p,boundary.MAX_KERNEL))==h for p,h in kernel_hashes.items())
        report['sourcesPreserved']=all(boundary.digest(boundary.regular_bytes(p,1024*1024))==h for p,h in pinned.items())
        report['sentinelPreserved']=sentinel.read_text()=='preserved'
        report['toolsPreserved']=boundary.toolchain(sdk)[3]==tool_hashes and all(boundary.digest(boundary.regular_bytes(p,256*1024*1024))==h for p,h in report['compilerToolHashes'].items())
        adapter=report.get('adapter',{})
        report['pass']=case=='positive' and adapter.get('pass') is True and reaped and report['sourcesPreserved'] and report['sentinelPreserved'] and report['toolsPreserved'] and report['kernelsPreserved'] and all(x['pass'] for x in records) and len(records)==8 and [(x.get('package'),x.get('hook')) for x in records if x.get('kind')=='hook']==[('fixture_b','build'),('fixture_a','build'),('fixture_a','link'),('fixture_b','link')]
        report['adverseCaseObserved']=bool(reaped and report['sourcesPreserved'] and report['sentinelPreserved'] and report['toolsPreserved'] and ((case=='hook-failure' and adapter.get('stockDeviceCalled') is False and adapter.get('failure')=='hook-build' and any(x.get('error')=='Confined child failed' and x.get('exitCode')==1 for x in records)) or (case=='hook-timeout' and adapter.get('stockDeviceCalled') is False and adapter.get('failure')=='hook-build' and any(x.get('reason')=='hook-deadline' for x in records)) or (case=='hook-output' and adapter.get('stockDeviceCalled') is False and adapter.get('failure')=='hook-build' and any(x.get('error')=='Fixed no-assets hook output refused' for x in records)) or (case=='hook-overflow' and adapter.get('stockDeviceCalled') is False and adapter.get('failure')=='hook-build' and any(x.get('reason')=='outputLimit' for x in records)) or (case=='malformed-message' and adapter.get('failure')=='session-identity') or (case=='wrong-token' and adapter.get('failure')=='session-refused') or (case=='oversized-message' and adapter.get('failure')=='message-bound') or (case=='engine-timeout' and adapter.get('failure')=='engine-deadline') or (case=='stop' and reason=='cancelled' and active_at is not None and len(records)==8 and all(x['pass'] for x in records))))
    finally:
        if process is not None:
            try:os.killpg(process.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            process.wait();process.stdout.close()
        for s,h in previous.items():signal.signal(s,h)
        report['canaryConnections']=0
        for listener in canary.sockets:
            try:
                connection,_=listener.accept();connection.close();report['canaryConnections']+=1
            except BlockingIOError:pass
        canary.close()
        report['pass']=bool(report['pass'] and report['canaryConnections']==0)
        report['adverseCaseObserved']=bool(report.get('adverseCaseObserved') and report['canaryConnections']==0 and report.get('kernelsPreserved'))
    (root/'report.json').write_text(json.dumps(report,indent=2));return report


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--synthetic-fixture',action='store_true',required=True);parser.add_argument('--sdk',required=True);parser.add_argument('--case',choices=CASES,default='positive');args=parser.parse_args()
    report=exercise(args.sdk,args.case);print(json.dumps(report));return 0 if report['pass'] or report.get('adverseCaseObserved') else 1

if __name__=='__main__':raise SystemExit(main())
