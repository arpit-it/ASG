// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/git_head_observation.dart';
import 'package:asg/services/git_metadata_host_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

String _reply() => jsonEncode({
  'version': 1,
  'layout': 'direct-dotgit-files',
  'scope': 'literal-file-declarations',
  'status': 'observed',
  'head_form': 'symbolic',
  'declared_ref': 'refs/heads/main',
  'declared_oid': '1' * 40,
  'oid_source': 'loose_ref',
  'reason': null,
  'git_state_verified': false,
  'working_tree': 'unknown',
  'ahead_behind': 'unknown',
  'conflict': 'unknown',
});

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
  NativeGitMetadataHost host({
    Duration deadline = const Duration(seconds: 2),
    bool supported = true,
  }) => NativeGitMetadataHost(
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
  GitMetadataReadRequest get request =>
      GitMetadataReadRequest(root: root.path, python: python);
  Future<void> clean() async {
    for (final child in children) {
      child.finish(-9);
    }
    if (await base.exists()) await base.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixture fixture;
  setUp(() async {
    final base = Directory(
      await (await Directory.systemTemp.createTemp('asg-git-host-test-'))
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
      expect(value.status, GitHeadStatus.observed);
      expect(value.gitStateVerified, isFalse);
      expect(fixture.starts, 1);
      expect(fixture.executable, fixture.python);
      expect(fixture.arguments!.take(3), ['-I', '-S', '-B']);
      expect(fixture.arguments!.skip(4), ['--root', fixture.root.path]);
      expect(path.dirname(fixture.arguments![3]), fixture.cwd);
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
          host.inspect(
            GitMetadataReadRequest(root: fixture.root.path, python: python),
          ),
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
        host.inspect(
          GitMetadataReadRequest(root: fixture.root.path, python: alias.path),
        ),
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
        'utf8',
        'duplicate',
        'nonzero',
        'stderr',
        'stderrLarge',
        'large',
        'splitLarge',
      ]) {
        fixture.respond = (p) {
          if (mode == 'invalid') {
            p.output.add(utf8.encode('private-sentinel'));
          } else if (mode == 'utf8') {
            p.output.add([255]);
          } else if (mode == 'duplicate') {
            p.output.add(
              utf8.encode(
                _reply().replaceFirst('"version":1', '"version":1,"version":1'),
              ),
            );
          } else if (mode == 'large') {
            p.output.add(List.filled(4097, 32));
          } else if (mode == 'splitLarge') {
            p.output.add(List.filled(4096, 32));
            p.output.add([32]);
          } else {
            p.output.add(utf8.encode(_reply()));
          }
          if (mode == 'stderr') p.errors.add(utf8.encode('private-sentinel'));
          if (mode == 'stderrLarge') p.errors.add(List.filled(4097, 65));
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

  test('exact4096 stdout bytes permitted and pipe EOF required', () async {
    fixture.respond = (p) {
      final bytes = utf8.encode(_reply());
      p.output.add([...bytes, ...List.filled(4096 - bytes.length, 32)]);
      p.finish();
    };
    final host = fixture.host();
    expect(
      (await host.inspect(fixture.request)).status,
      GitHeadStatus.observed,
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
      final host = NativeGitMetadataHost(
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
    'known existing Python reads only disposable Mac metadata fixture',
    () async {
      const python =
          '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12';
      if (!await File(python).exists()) {
        fail('Known existing fixture Python is unavailable.');
      }
      final git = await Directory(
        path.join(fixture.root.path, '.git/refs/heads'),
      ).create(recursive: true);
      await File(path.join(git.path, 'main')).writeAsString('${'2' * 40}\n');
      await File(path.join(fixture.root.path, '.git/HEAD'))
          .writeAsString('ref: refs/heads/main\n');
      final before = await File(path.join(git.path, 'main')).readAsString();
      final host = NativeGitMetadataHost(
        loadAsset: () => File('tools/git_head_metadata.py').readAsString(),
      );
      final value = await host.inspect(
        GitMetadataReadRequest(root: fixture.root.path, python: python),
      );
      expect(value.declaredOid, '2' * 40);
      expect(value.gitStateVerified, isFalse);
      expect(await File(path.join(git.path, 'main')).readAsString(), before);
      await host.dispose();
    },
    skip: !Platform.isMacOS
        ? 'Known Mac Python/real host fixture; portable fake lifecycle cases remain active.'
        : false,
  );
}
