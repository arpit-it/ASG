// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:asg/models/project_instruction_observation.dart';
import 'package:asg/services/project_instruction_host_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

const _manifest = 'Untrusted fixture instructions\r\n';
String _reply({List<int>? bytes}) {
  final data = bytes ?? utf8.encode(_manifest);
  return jsonEncode({
    'version': 1,
    'scope': 'project-instruction-documents',
    'status': 'observed',
    'reason': null,
    'selected_paths': ['AGENTS.md'],
    'documents': [
      {
        'path': 'AGENTS.md',
        'byte_length': data.length,
        'sha256': sha256.convert(data).toString(),
        'content_base64': base64Encode(data),
      },
    ],
    'source_verified': false,
  });
}

ProjectInstructionReadRequest _request({
  required String root,
  required String python,
}) => ProjectInstructionReadRequest(
  root: root,
  python: python,
  selectedPaths: ['AGENTS.md'],
);

class _Process implements Process {
  final output = StreamController<List<int>>(),
      errors = StreamController<List<int>>();
  final exited = Completer<int>();
  final signals = <ProcessSignal>[];
  bool autoReap = true;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => throw StateError('Saved PID operations forbidden.');
  @override
  IOSink get stdin => throw StateError('No stdin protocol.');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (autoReap) finish(-9);
    return true;
  }

  void finish([int code = 0, bool closePipes = true]) {
    if (!exited.isCompleted) exited.complete(code);
    if (closePipes) {
      if (!output.isClosed) unawaited(output.close());
      if (!errors.isClosed) unawaited(errors.close());
    }
  }
}

class _Deadline implements Timer {
  _Deadline(this.callback);
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
  @override
  void cancel() => _active = false;
  void fire() {
    if (_active) {
      _active = false;
      callback();
    }
  }
}

class _Fixture {
  _Fixture(this.base, this.root, this.python);
  final Directory base, root;
  final String python;
  final temps = <Directory>[];
  final children = <_Process>[];
  final started = Completer<void>();
  int assets = 0, starts = 0;
  bool manualDeadline = false;
  void Function()? fireDeadline;
  List<String>? arguments;
  String? executable, cwd;
  Future<Process> Function(_Process)? start;
  void Function(_Process)? respond;
  Future<String> Function()? asset;
  NativeProjectInstructionHost host({
    Duration deadline = const Duration(seconds: 2),
    bool supported = true,
  }) => NativeProjectInstructionHost(
    platformSupported: supported,
    deadline: deadline,
    createTimer: manualDeadline
        ? (duration, callback) {
            expect(duration, deadline);
            final timer = _Deadline(callback);
            fireDeadline = timer.fire;
            return timer;
          }
        : null,
    loadAsset: () async {
      assets++;
      return asset == null ? '# trusted fixed fixture asset' : await asset!();
    },
    createTemp: () async {
      final temp = await Directory(path.join(base.path, 'temps'))
          .create(recursive: true);
      final result = await temp.createTemp('owned-');
      if (!Platform.isMacOS) {
        final chmod = await Process.run('/bin/chmod', [
          '0700',
          result.path,
        ], runInShell: false);
        if (chmod.exitCode != 0) {
          throw StateError('Private test directory unavailable.');
        }
      }
      temps.add(result);
      return result;
    },
    startProcess:
        (
          exe,
          args, {
          required workingDirectory,
          required runInShell,
          required includeParentEnvironment,
          required environment,
        }) async {
          starts++;
          executable = exe;
          arguments = List.of(args);
          cwd = workingDirectory;
          expect(runInShell, isFalse);
          expect(includeParentEnvironment, isFalse);
          expect(environment, isEmpty);
          final child = _Process();
          children.add(child);
          if (!started.isCompleted) started.complete();
          if (start != null) return start!(child);
          (respond ??
              (p) {
                p.output.add(utf8.encode(_reply()));
                p.finish();
              })(child);
          return child;
        },
  );
  ProjectInstructionReadRequest get request =>
      _request(root: root.path, python: python);
  Future<void> clean() async {
    for (final child in children) {
      child.finish(-9);
    }
    if (await base.exists()) await base.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() async {
    final base = Directory(
      await (await Directory.systemTemp.createTemp('asg-project-host-test-'))
          .resolveSymbolicLinks(),
    );
    final root = await Directory(path.join(base.path, 'project')).create();
    // Fake-process tests inspect this existing executable but never execute it.
    final python = await File('/usr/bin/python3').resolveSymbolicLinks();
    fixture = _Fixture(base, root, python);
  });
  tearDown(() async {
    await fixture.clean();
  });

  test(
    'fixed isolated launch and successful EOF cleanup precede publication',
    () async {
      final host = fixture.host();
      final value = await host.inspect(fixture.request);
      expect(value.status, ProjectInstructionStatus.observed);
      expect(value.sourceVerified, isFalse);
      expect(fixture.starts, 1);
      expect(fixture.executable, fixture.python);
      expect(fixture.arguments!.take(3), ['-I', '-S', '-B']);
      expect(fixture.arguments!.skip(4), [
        '--root',
        fixture.root.path,
        '--file',
        'AGENTS.md',
      ]);
      expect(path.dirname(fixture.arguments![3]), fixture.cwd);
      expect(
        path.basename(fixture.arguments![3]),
        'project_instruction_documents.py',
      );
      expect(path.isWithin(fixture.root.path, fixture.cwd!), isFalse);
      expect(await fixture.temps.single.exists(), isFalse);
      expect(fixture.children.single.signals, isEmpty);
      await host.dispose();
    },
  );

  test(
    'relative missing directory and in-root interpreters never launch',
    () async {
      final inside = File(path.join(fixture.root.path, 'python'));
      await inside.writeAsString('not executable');
      for (final python in [
        'python3',
        path.join(fixture.base.path, 'missing'),
        fixture.root.path,
        inside.path,
      ]) {
        final host = fixture.host();
        await expectLater(
          host.inspect(_request(root: fixture.root.path, python: python)),
          throwsStateError,
        );
        await host.cancel();
        expect(fixture.starts, 0);
        await host.dispose();
      }
    },
  );

  test(
    'configured outside symlink resolving into project refuses before asset',
    () async {
      final alias = Link(path.join(fixture.base.path, 'python-alias'));
      await alias.create(path.join(fixture.root.path, 'private-python'));
      final host = fixture.host();
      await expectLater(
        host.inspect(_request(root: fixture.root.path, python: alias.path)),
        throwsStateError,
      );
      expect(fixture.assets, 0);
      expect(fixture.starts, 0);
      await host.dispose();
    },
  );

  test('unsupported and disposed hosts do not load or start', () async {
    final host = fixture.host(supported: false);
    expect(host.supported, isFalse);
    await expectLater(host.inspect(fixture.request), throwsStateError);
    await host.dispose();
    expect(fixture.starts, 0);
    expect(fixture.assets, 0);
    final disposed = fixture.host();
    await disposed.dispose();
    await expectLater(disposed.inspect(fixture.request), throwsStateError);
    expect(fixture.starts, 0);
  });

  test('asset failure is private and creates no temp or child', () async {
    fixture.asset = () async => throw StateError('private-sentinel');
    final host = fixture.host();
    await expectLater(
      host.inspect(fixture.request),
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'private error',
          isNot(contains('sentinel')),
        ),
      ),
    );
    expect(fixture.temps, isEmpty);
    expect(fixture.starts, 0);
    await host.dispose();
  });

  test(
    'changed selected root refuses instead of silently retargeting',
    () async {
      fixture.asset = () async {
        await fixture.root.rename(path.join(fixture.base.path, 'held-project'));
        await Link(fixture.root.path).create(fixture.base.path);
        return '# trusted asset';
      };
      final host = fixture.host();
      await expectLater(host.inspect(fixture.request), throwsStateError);
      expect(fixture.starts, 0);
      await host.dispose();
    },
  );

  test('start failure reaps nothing and cleans owned temp privately', () async {
    fixture.start = (_) async => throw StateError('private-sentinel');
    final host = fixture.host();
    await expectLater(host.inspect(fixture.request), throwsStateError);
    expect(await fixture.temps.single.exists(), isFalse);
    await host.dispose();
  });

  test(
    'malformed output nonzero status stderr and byte overflow refuse',
    () async {
      for (final mode in [
        'invalid',
        'empty',
        'trailing',
        'schema',
        'manifestLarge',
        'utf8',
        'duplicate',
        'nonzero',
        'stderr',
        'stderrLarge',
        'stderrExact',
        'large',
        'splitLarge',
      ]) {
        fixture.respond = (p) {
          if (mode == 'invalid') {
            p.output.add(utf8.encode('private-sentinel'));
          } else if (mode == 'empty') {
            // Empty output must not be mistaken for a typed helper refusal.
          } else if (mode == 'trailing') {
            p.output.add(utf8.encode('${_reply()}private-sentinel'));
          } else if (mode == 'schema') {
            p.output.add(utf8.encode(_reply().replaceFirst('false', 'true')));
          } else if (mode == 'manifestLarge') {
            p.output.add(utf8.encode(_reply(bytes: List.filled(65537, 0))));
          } else if (mode == 'utf8') {
            p.output.add([255]);
          } else if (mode == 'duplicate') {
            p.output.add(
              utf8.encode(
                _reply().replaceFirst('"version":1', '"version":1,"version":1'),
              ),
            );
          } else if (mode == 'large') {
            p.output.add(List.filled(131073, 32));
          } else if (mode == 'splitLarge') {
            p.output.add(List.filled(131072, 32));
            p.output.add([32]);
          } else {
            p.output.add(utf8.encode(_reply()));
          }
          if (mode == 'stderr') p.errors.add(utf8.encode('private-sentinel'));
          if (mode == 'stderrLarge') p.errors.add(List.filled(4097, 65));
          if (mode == 'stderrExact') p.errors.add(List.filled(4096, 65));
          p.finish(mode == 'nonzero' ? 1 : 0);
        };
        final host = fixture.host();
        await expectLater(
          host.inspect(fixture.request),
          throwsA(
            isA<StateError>().having(
              (e) => e.toString(),
              mode,
              isNot(contains('sentinel')),
            ),
          ),
        );
        await host.cancel();
        await host.dispose();
      }
      for (final temp in fixture.temps) {
        expect(await temp.exists(), isFalse);
      }
    },
  );

  test('exact128KiB stdout bytes permitted and pipe EOF required', () async {
    fixture.respond = (p) {
      final bytes = utf8.encode(_reply());
      p.output.add([...bytes, ...List.filled(131072 - bytes.length, 32)]);
      p.finish();
    };
    final host = fixture.host();
    expect(
      (await host.inspect(fixture.request)).status,
      ProjectInstructionStatus.observed,
    );
    await host.dispose();
  });

  test(
    'exit zero with stalled pipes times out and settles cancellation',
    () async {
      fixture.respond = (p) {
        p.output.add(utf8.encode(_reply()));
        p.finish(0, false);
      };
      fixture.manualDeadline = true;
      final host = fixture.host();
      final refused = expectLater(
        host.inspect(fixture.request),
        throwsStateError,
      );
      while (fixture.children.isEmpty ||
          !fixture.children.single.output.hasListener) {
        await Future<void>.delayed(Duration.zero);
      }
      fixture.fireDeadline!();
      await refused;
      await host.cancel();
      expect(await fixture.temps.single.exists(), isFalse);
      await host.dispose();
    },
  );

  test('busy second operation does not start another child', () async {
    fixture.respond = (_) {};
    final host = fixture.host();
    final pending = host.inspect(fixture.request);
    final refused = expectLater(pending, throwsStateError);
    await fixture.started.future;
    await expectLater(host.inspect(fixture.request), throwsStateError);
    expect(fixture.starts, 1);
    await host.cancel();
    await refused;
    expect(fixture.children.single.signals, [ProcessSignal.sigkill]);
    await host.dispose();
  });

  test('cancel during asset loading prevents future startup', () async {
    final asset = Completer<String>();
    fixture.asset = () => asset.future;
    final host = fixture.host();
    final pending = host.inspect(fixture.request);
    final refused = expectLater(pending, throwsStateError);
    while (fixture.assets == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    var settled = false;
    final stop = host.cancel().then((_) => settled = true);
    await refused;
    expect(settled, isFalse);
    asset.complete('# trusted');
    await stop;
    expect(fixture.starts, 0);
    await host.dispose();
  });

  test(
    'late startup cancellation owns kill/reap and blocks new reads',
    () async {
      final start = Completer<Process>();
      fixture.start = (_) => start.future;
      final host = fixture.host();
      final pending = host.inspect(fixture.request);
      final refused = expectLater(pending, throwsStateError);
      await fixture.started.future;
      var settled = false;
      final stop = host.cancel().then((_) => settled = true);
      await refused;
      await expectLater(host.inspect(fixture.request), throwsStateError);
      expect(settled, isFalse);
      final child = fixture.children.single;
      child.autoReap = false;
      start.complete(child);
      while (child.signals.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(settled, isFalse);
      expect(await fixture.temps.single.exists(), isTrue);
      child.finish(-9);
      await stop;
      expect(await fixture.temps.single.exists(), isFalse);
      await host.dispose();
    },
  );

  test(
    'startup timeout retains late handle and dispose waits for reaping',
    () async {
      final start = Completer<Process>();
      fixture.start = (_) => start.future;
      fixture.manualDeadline = true;
      final host = fixture.host();
      final pending = host.inspect(fixture.request);
      final refused = expectLater(pending, throwsStateError);
      await fixture.started.future;
      fixture.fireDeadline!();
      await refused;
      var disposed = false;
      final disposal = host.dispose().then((_) => disposed = true);
      expect(disposed, isFalse);
      start.complete(fixture.children.single);
      await disposal;
      expect(fixture.children.single.signals, [ProcessSignal.sigkill]);
      expect(await fixture.temps.single.exists(), isFalse);
    },
  );

  test('concurrent cancel and dispose share one owned cleanup', () async {
    fixture.respond = (p) {
      p.autoReap = false;
    };
    final host = fixture.host();
    final refused = expectLater(
      host.inspect(fixture.request),
      throwsStateError,
    );
    await fixture.started.future;
    final stops = [host.cancel(), host.cancel(), host.dispose()];
    await refused;
    final child = fixture.children.single;
    while (child.signals.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(child.signals, [ProcessSignal.sigkill]);
    expect(await fixture.temps.single.exists(), isTrue);
    child.finish(-9);
    await Future.wait(stops);
    expect(await fixture.temps.single.exists(), isFalse);
    await expectLater(host.inspect(fixture.request), throwsStateError);
  });

  test('stream errors are private and kill/reap the owned child', () async {
    fixture.respond = (p) {
      p.output.addError(StateError('private-sentinel'));
    };
    final host = fixture.host();
    await expectLater(
      host.inspect(fixture.request),
      throwsA(
        isA<StateError>().having(
          (e) => e.toString(),
          'private',
          isNot(contains('sentinel')),
        ),
      ),
    );
    expect(fixture.children.single.signals, [ProcessSignal.sigkill]);
    expect(await fixture.temps.single.exists(), isFalse);
    await host.dispose();
  });

  test(
    'unexpected temp entry blocks further work instead of recursive deletion',
    () async {
      fixture.respond = (p) {
        File(path.join(fixture.cwd!, 'unexpected'))
            .writeAsStringSync('preserve');
        p.output.add(utf8.encode(_reply()));
        p.finish();
      };
      final host = fixture.host();
      await expectLater(host.inspect(fixture.request), throwsStateError);
      expect(
        await File(path.join(fixture.cwd!, 'unexpected')).readAsString(),
        'preserve',
      );
      await expectLater(host.cancel(), throwsStateError);
      await expectLater(host.inspect(fixture.request), throwsStateError);
      expect(fixture.starts, 1);
      await expectLater(host.dispose(), throwsStateError);
    },
  );

  test(
    'inside-root temp injection is refused without deleting project data',
    () async {
      final sentinel = File(path.join(fixture.root.path, 'retain'));
      await sentinel.writeAsString('preserve');
      final host = NativeProjectInstructionHost(
        platformSupported: true,
        loadAsset: () async => '# trusted',
        createTemp: () async => fixture.root,
      );
      await expectLater(host.inspect(fixture.request), throwsStateError);
      expect(await sentinel.readAsString(), 'preserve');
      await host.dispose();
    },
  );

  test(
    'configured Python alias retarget after asset loading never launches',
    () async {
      final alias = Link(path.join(fixture.base.path, 'configured-python'));
      await alias.create(fixture.python);
      final inside = File(path.join(fixture.root.path, 'private-python'));
      await inside.writeAsString('not a trusted interpreter');
      fixture.asset = () async {
        await alias.delete();
        await alias.create(inside.path);
        return '# trusted';
      };
      final host = fixture.host();
      await expectLater(
        host.inspect(_request(root: fixture.root.path, python: alias.path)),
        throwsStateError,
      );
      expect(fixture.starts, 0);
      expect(await fixture.temps.single.exists(), isFalse);
      await host.dispose();
    },
  );

  test(
    'retargeted owned temp is preserved and cleanup stays uncertain',
    () async {
      final sentinel = File(
        path.join(fixture.root.path, 'git-proof-irrelevant-sentinel'),
      );
      await sentinel.writeAsString('preserve project data');
      fixture.respond = (p) {
        Directory(fixture.cwd!).renameSync('${fixture.cwd!}-held');
        Link(fixture.cwd!).createSync(fixture.root.path);
        p.output.add(utf8.encode(_reply()));
        p.finish();
      };
      final host = fixture.host();
      await expectLater(host.inspect(fixture.request), throwsStateError);
      await expectLater(host.cancel(), throwsStateError);
      expect(await sentinel.readAsString(), 'preserve project data');
      await expectLater(host.inspect(fixture.request), throwsStateError);
      expect(fixture.starts, 1);
      await expectLater(host.dispose(), throwsStateError);
    },
  );

  test(
    'cancel waits for late temp creation and removes only adopted temp',
    () async {
      final creating = Completer<void>(), tempReady = Completer<Directory>();
      final host = NativeProjectInstructionHost(
        platformSupported: true,
        loadAsset: () async => '# trusted',
        createTemp: () {
          creating.complete();
          return tempReady.future;
        },
      );
      final refused = expectLater(
        host.inspect(fixture.request),
        throwsStateError,
      );
      await creating.future;
      var settled = false;
      final stop = host.cancel().then((_) => settled = true);
      await refused;
      expect(settled, isFalse);
      final temp = await fixture.base.createTemp('late-owned-');
      if (!Platform.isMacOS) {
        final result = await Process.run('/bin/chmod', [
          '0700',
          temp.path,
        ], runInShell: false);
        expect(result.exitCode, 0);
      }
      tempReady.complete(temp);
      await stop;
      expect(await temp.exists(), isFalse);
      await host.dispose();
    },
  );

  test(
    'maximum document bytes retain exact provenance without authority',
    () async {
      final bytes = List.generate(32768, (i) => 65 + i % 26);
      fixture.respond = (p) {
        p.output.add(utf8.encode(_reply(bytes: bytes)));
        p.finish();
      };
      final host = fixture.host();
      final value = await host.inspect(fixture.request);
      expect(value.documents.single.bytes, bytes);
      expect(value.sourceVerified, isFalse);
      await host.dispose();
    },
  );

  test(
    'typed helper refusal is fresh metadata, not transport fallback',
    () async {
      fixture.respond = (p) {
        p.output.add(
          utf8.encode(
            jsonEncode({
              'version': 1,
              'scope': 'project-instruction-documents',
              'status': 'changed',
              'reason': 'document_changed',
              'selected_paths': ['AGENTS.md'],
              'documents': [],
              'source_verified': false,
            }),
          ),
        );
        p.finish();
      };
      final host = fixture.host();
      final value = await host.inspect(fixture.request);
      expect(value.status, ProjectInstructionStatus.changed);
      expect(value.documents, isEmpty);
      expect(value.sourceVerified, isFalse);
      await host.dispose();
    },
  );

  test(
    'known Mac Python observes only selected disposable documents',
    () async {
      const python =
          '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12';
      expect(await File(python).exists(), true);
      final selected = File(path.join(fixture.root.path, 'AGENTS.md'));
      await selected.writeAsString(_manifest);
      final host = NativeProjectInstructionHost();
      final value = await host.inspect(
        _request(root: fixture.root.path, python: python),
      );
      expect(value.documents.single.text, _manifest);
      expect(value.sourceVerified, false);
      expect(await selected.readAsString(), _manifest);
      await host.dispose();
    },
    skip: !Platform.isMacOS
        ? 'Known Mac Python; portable lifecycle cases remain active.'
        : false,
  );
  test('valid response for another selected readset refuses', () async {
    fixture.respond = (p) {
      p.output.add(utf8.encode(_reply().replaceAll('AGENTS.md', 'README.md')));
      p.finish();
    };
    final host = fixture.host();
    await expectLater(host.inspect(fixture.request), throwsStateError);
    await host.cancel();
    await host.dispose();
  });
}
