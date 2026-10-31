// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/models/model_catalog.dart';

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/runtime_setup_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/models/runtime_capabilities.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/runtime_connection.dart';
import 'package:asg/services/runtime_host.dart';
import 'package:asg/services/runtime_host_native.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/views/runtime_setup_screen.dart';
import 'package:asg/views/studio_app.dart';
import 'package:asg/views/dashboard.dart';
import 'package:asg/services/studio_store.dart';

// The filesystem-only scanner is portable; production managed setup stays macOS-only.
class ScanningRuntimeHost extends NativeRuntimeHost {
  @override
  bool get supported => true;
}

class FakeRuntimeHost implements RuntimeHost {
  FakeRuntimeHost({this.supported = true});
  @override
  final bool supported;
  @override
  bool ownsProcess = false;
  @override
  bool get loading => false;
  @override
  bool get working => false;
  int downloads = 0, stops = 0;
  @override
  Stream<String> get events => const Stream.empty();
  @override
  Future<String?> chooseDirectory() async => '/models';
  @override
  Future<String?> choosePython() async => '/python';
  @override
  Future<List<ModelCandidate>> scan(String path) async => [
    ModelCandidate(
      path: path,
      name: 'Qwen3.5-9B',
      supported: true,
      detail: 'Complete checkpoint',
    ),
  ];
  @override
  Future<void> prepare(String python) async {}
  @override
  Future<RuntimeCapabilities> discover(String python) async =>
      throw UnimplementedError();
  @override
  Future<String> download(RuntimeSetup setup) async {
    downloads++;
    return '/models/Qwen3.5-9B';
  }

  @override
  Future<void> start(RuntimeSetup setup, String modelId) async {
    ownsProcess = true;
  }

  @override
  Future<void> stop() async {
    if (!ownsProcess) throw StateError('Not owned');
    ownsProcess = false;
    stops++;
  }
}

class DownloadRuntimeHost extends FakeRuntimeHost {
  bool fail = true;
  Completer<void>? gate;
  final entered = Completer<void>();
  int scans = 0;
  @override
  Future<String> download(RuntimeSetup setup) async {
    downloads++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (fail) {
      throw FileSystemException(
        'PRIVATE_DOWNLOAD token=secret',
        '/private/model',
      );
    }
    return '/models/downloaded';
  }

  @override
  Future<List<ModelCandidate>> scan(String path) async {
    scans++;
    return super.scan(path);
  }
}

class StartRuntimeHost extends FakeRuntimeHost {
  bool fail = true;
  Completer<void>? gate;
  final entered = Completer<void>();
  int launches = 0;
  @override
  Future<void> start(RuntimeSetup setup, String modelId) async {
    launches++;
    if (!entered.isCompleted) entered.complete();
    await gate?.future;
    if (fail) {
      throw ProcessException('/private/python', [
        'token=PRIVATE_START',
      ], 'PRIVATE_START failed');
    }
    await super.start(setup, modelId);
  }
}

class ScanRuntimeHost extends FakeRuntimeHost {
  bool fail = false;
  Completer<void>? gate;
  @override
  Future<List<ModelCandidate>> scan(String path) async {
    await gate?.future;
    if (fail) {
      throw FileSystemException('PRIVATE_SCAN token=secret', '/private/model');
    }
    return super.scan(path);
  }
}

class StopRuntimeHost extends FakeRuntimeHost {
  bool fail = true;
  Completer<void>? gate;
  @override
  Future<void> stop() async {
    await gate?.future;
    if (fail) {
      throw ProcessException('/private/python', [
        'token=PRIVATE_STOP',
      ], 'PRIVATE_STOP failed');
    }
    await super.stop();
  }
}

class PrepareRuntimeHost extends FakeRuntimeHost {
  bool fail = true;
  Completer<void>? gate;
  int preparations = 0;
  @override
  Future<void> prepare(String python) async {
    preparations++;
    await gate?.future;
    if (fail) {
      throw ProcessException('/private/python', [
        'token=PRIVATE_PREPARE',
      ], 'PRIVATE_PREPARE failed');
    }
  }
}

class PickerRuntimeHost extends FakeRuntimeHost {
  bool fail = true;
  bool cancel = false;
  @override
  Future<String?> chooseDirectory() async {
    if (fail) {
      throw StateError('PRIVATE_PICKER_SENTINEL token=secret /private/models');
    }
    return cancel ? null : '/models';
  }

  @override
  Future<String?> choosePython() async {
    if (fail) {
      throw StateError('PRIVATE_PICKER_SENTINEL token=secret /private/python');
    }
    return cancel ? null : '/python';
  }
}

class DelayedStartupHost extends FakeRuntimeHost {
  Completer<void>? scanGate, launchGate;
  final entered = Completer<void>();
  int launches = 0;
  @override
  Future<List<ModelCandidate>> scan(String path) async {
    if (scanGate != null) {
      entered.complete();
      await scanGate!.future;
    }
    return super.scan(path);
  }

  @override
  Future<void> start(RuntimeSetup setup, String modelId) async {
    launches++;
    if (launchGate != null) {
      entered.complete();
      await launchGate!.future;
    }
    await super.start(setup, modelId);
  }

  @override
  Future<void> stop() async {
    if (ownsProcess) await super.stop();
  }
}

class CancelledLaunchHost extends DelayedStartupHost {
  bool failStop = true;
  Completer<void>? stopGate;
  final stopping = Completer<void>();
  @override
  Future<void> stop() async {
    if (!ownsProcess) return;
    if (!stopping.isCompleted) stopping.complete();
    await stopGate?.future;
    if (failStop) {
      throw ProcessException('/private/python', [
        'token=PRIVATE_CLEANUP',
      ], 'PRIVATE_CLEANUP failed');
    }
    await super.stop();
  }
}

RuntimeConnection connection({
  required bool Function() ready,
  String model = 'Qwen3.5-9B',
  String? path,
}) => RuntimeConnection(
  client: MockClient(
    (_) async => http.Response(
      jsonEncode({
        'status': ready() ? 'ready' : 'loading',
        'model': model,
        'model_path': path,
      }),
      200,
    ),
  ),
);
Future<RuntimeSetupController> controller(
  FakeRuntimeHost host, {
  RuntimeConnection? api,
  ProviderFactory? createProvider,
  Future<ModelHardware> Function()? inspectMemory,
}) async {
  final prefs = await SharedPreferences.getInstance();
  return RuntimeSetupController(
    store: RuntimeSetupStore.fromPreferences(prefs),
    modelStore: ModelSettingsStore.fromPreferences(prefs),
    host: host,
    inspectMemory:
        inspectMemory ?? () async => const ModelHardware(appleSilicon: false),
    createProvider: createProvider,
    connection: api ?? connection(ready: () => false),
  );
}

class PendingConnectionStore extends ModelSettingsStore {
  PendingConnectionStore(super.records);
  final entered = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> save(LocalModelConfig config) async {
    entered.complete();
    await release.future;
    await super.save(config);
  }
}

class FailingConnectionStore extends ModelSettingsStore {
  FailingConnectionStore(super.records);
  bool fail = true;
  @override
  Future<void> save(LocalModelConfig config) async {
    if (fail) {
      throw StateError('PRIVATE_SAVE_SENTINEL token=secret /private/record');
    }
    await super.save(config);
  }
}

class FailingSetupStore extends RuntimeSetupStore {
  FailingSetupStore(super.records);
  bool fail = true;
  @override
  Future<void> save(RuntimeSetup setup) async {
    if (fail) {
      throw StateError('PRIVATE_SETUP_SENTINEL token=secret /private/setup');
    }
    await super.save(setup);
  }
}

class SetupProbe implements ModelProvider {
  final output = StreamController<String>();
  int cancellations = 0;
  @override
  Stream<String> generate(String prompt) => output.stream;
  @override
  Future<void> cancel() async {
    cancellations++;
  }
}

void main() {
  test('resident observation requires fresh idle local MLX and exact persisted identity', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = RuntimeSetupStore.fromPreferences(prefs);
    final modelStore = ModelSettingsStore.fromPreferences(prefs);
    final revision = 'a' * 40;
    await store.save(
      RuntimeSetup(
        modelPath: '/models/current',
        repository: 'mlx-community/Qwen3.8-27B-4bit',
        revision: revision,
      ),
    );
    await modelStore.save(const LocalModelConfig(model: 'current'));
    final data = <String, Object?>{
      'status': 'ready',
      'phase': 'idle',
      'model': 'current',
      'model_path': '/models/current',
      'backend': 'mlx',
      'device': 'metal',
    };
    final c = RuntimeSetupController(
      store: store,
      modelStore: modelStore,
      host: FakeRuntimeHost(),
      connection: RuntimeConnection(
        client: MockClient((_) async => http.Response(jsonEncode(data), 200)),
      ),
    );
    c.initialize();
    final observed = await c.inspectRunningCatalogModel();
    expect(observed?.model, 'current');
    await c.saveSetup(
      RuntimeSetup(
        modelPath: '/models/current',
        repository: 'mlx-community/another-model',
        revision: 'b' * 40,
      ),
    );
    expect((await c.inspectRunningCatalogModel())?.model, 'current');
    for (final mismatch in [
      <String, Object?>{'phase': 'writing'},
      {'phase': null},
      {'model': 'other'},
      {'model_path': '/other'},
      {'backend': 'torch'},
      {'status': 'loading'},
    ]) {
      final original = Map<String, Object?>.of(data);
      data.addAll(mismatch);
      expect(await c.inspectRunningCatalogModel(), isNull);
      data
        ..clear()
        ..addAll(original);
    }
    c.dispose();
    expect(await c.inspectRunningCatalogModel(), isNull);
  });

  test('Download failure is private, terminal and retryable', () async {
    SharedPreferences.setMockInitialValues({});
    final host = DownloadRuntimeHost()..gate = Completer<void>();
    final c = await controller(host);
    await c.inspect('/models/existing');
    final selected = c.selected;
    const setup = RuntimeSetup(
      repository: 'owner/model',
      downloadParent: '/models',
    );
    final pending = c.download(setup);
    await host.entered.future;
    await c.download(setup);
    expect(host.downloads, 1);
    host.gate!.complete();
    await pending;
    expect(c.busy, isFalse);
    expect(c.status, 'Model download failed.');
    expect(c.error, contains('Could not download model files'));
    expect(c.error, contains('retry'));
    for (final secret in [
      'PRIVATE_DOWNLOAD',
      '/private/model',
      'token=secret',
    ]) {
      expect('${c.error} ${c.status} ${c.logs}', isNot(contains(secret)));
    }
    expect(c.selected, same(selected));
    expect(c.setup.repository, setup.repository);
    expect(host.scans, 1);
    host.fail = false;
    host.gate = null;
    await c.download(setup);
    expect(c.error, isNull);
    expect(c.selected?.path, '/models/downloaded');
    expect(c.status, contains('Download complete'));
    expect(host.downloads, 2);
    c.dispose();
  });
  for (final fail in [true, false]) {
    test('Disposed download completion is ignored (failure: $fail)', () async {
      SharedPreferences.setMockInitialValues({});
      final host = DownloadRuntimeHost()
        ..fail = fail
        ..gate = Completer<void>();
      final c = await controller(host);
      final pending = c.download(const RuntimeSetup(repository: 'owner/model'));
      await host.entered.future;
      final status = c.status;
      var notifications = 0;
      c.addListener(() => notifications++);
      c.dispose();
      host.gate!.complete();
      await pending;
      expect(c.error, isNull);
      expect(c.status, status);
      expect(host.scans, 0);
      expect(notifications, 0);
    });
  }

  test('Start launch failure is private, terminal and retryable', () async {
    SharedPreferences.setMockInitialValues({});
    final host = StartRuntimeHost();
    final c = await controller(
      host,
      api: connection(ready: () => host.ownsProcess, path: '/models'),
    );
    addTearDown(c.dispose);
    await c.inspect('/models');
    final selected = c.selected;
    final originalConnection = c.modelStore.load();
    await c.start(const RuntimeSetup(python: '/python'));
    final diagnostics = '${c.error} ${c.status} ${c.logs.join(' ')}';
    expect(diagnostics, isNot(contains('PRIVATE_START')));
    expect(diagnostics, isNot(contains('/private/')));
    expect(c.error, contains('retry'));
    expect(c.error, contains('Python'));
    expect(c.status, contains('failed'));
    expect(c.busy, isFalse);
    expect(c.selected, same(selected));
    expect(c.setup.modelPath, '/models');
    expect(
      [
        c.modelStore.load().baseUrl,
        c.modelStore.load().model,
        c.modelStore.load().chatOutputTokens,
      ],
      [
        originalConnection.baseUrl,
        originalConnection.model,
        originalConnection.chatOutputTokens,
      ],
    );
    expect(host.ownsProcess, isFalse);
    host.fail = false;
    await c.start(const RuntimeSetup(python: '/python'));
    expect(c.error, isNull);
    expect(c.health.ready, isTrue);
    expect(c.status, contains('Runtime ready'));
    expect(c.modelStore.load().model, 'Qwen3.5-9B');
    expect(host.launches, 2);
  });

  test(
    'Start excludes duplicate launch and ignores disposed failure',
    () async {
      SharedPreferences.setMockInitialValues({});
      final host = StartRuntimeHost()..gate = Completer<void>();
      final c = await controller(host);
      await c.inspect('/models');
      final pending = c.start(const RuntimeSetup());
      await host.entered.future;
      expect(c.busy, isTrue);
      await c.start(const RuntimeSetup());
      expect(host.launches, 1);
      final status = c.status;
      final savedConnection = [
        c.modelStore.load().baseUrl,
        c.modelStore.load().model,
        c.modelStore.load().chatOutputTokens,
      ];
      c.dispose();
      host.gate!.complete();
      await pending;
      expect(c.error, isNull);
      expect(c.status, status);
      expect([
        c.modelStore.load().baseUrl,
        c.modelStore.load().model,
        c.modelStore.load().chatOutputTokens,
      ], savedConnection);
      expect(host.ownsProcess, isFalse);
    },
  );

  for (final action in ['inspect', 'download', 'start']) {
    test('scan failure is private and retryable during $action', () async {
      SharedPreferences.setMockInitialValues({});
      final host = ScanRuntimeHost();
      final c = await controller(host);
      addTearDown(c.dispose);
      await c.inspect('/models');
      final selected = c.selected;
      host.fail = true;
      if (action == 'inspect') {
        await c.inspect('/other');
      } else if (action == 'download') {
        await c.download(const RuntimeSetup(repository: 'owner/model'));
      } else {
        await c.start(const RuntimeSetup());
      }
      expect(c.error, isNot(contains('PRIVATE_SCAN')));
      expect(c.error, isNot(contains('/private/')));
      expect(c.error, contains('retry'));
      expect(c.status, contains('failed'));
      expect(c.busy, isFalse);
      expect(c.selected, same(selected));
      expect(host.ownsProcess, isFalse);
      host.fail = false;
      await c.inspect('/recovered');
      expect(c.error, isNull);
      expect(c.selected?.path, '/recovered');
      expect(c.status, contains('found'));
    });
  }
  test('disposed scan failure cannot publish diagnostics', () async {
    SharedPreferences.setMockInitialValues({});
    final host = ScanRuntimeHost()..fail = true;
    host.gate = Completer<void>();
    final c = await controller(host);
    final pending = c.inspect('/models');
    final status = c.status;
    c.dispose();
    host.gate!.complete();
    await pending;
    expect(c.error, isNull);
    expect(c.status, status);
  });

  test(
    'Stop failures are private and successful retry clears diagnostics',
    () async {
      SharedPreferences.setMockInitialValues({});
      final host = StopRuntimeHost()..ownsProcess = true;
      final c = await controller(host);
      addTearDown(c.dispose);
      await c.stop();
      expect(c.error, isNot(contains('PRIVATE_STOP')));
      expect(c.error, isNot(contains('/private/')));
      expect(c.error, contains('retry'));
      expect(c.status, contains('failed'));
      expect(host.ownsProcess, isTrue);
      host.fail = false;
      await c.stop();
      expect(c.error, isNull);
      expect(c.status, 'Managed runtime stopped.');
      expect(host.ownsProcess, isFalse);
    },
  );
  for (final fail in [false, true]) {
    test('disposed Stop ignores delayed completion: $fail', () async {
      SharedPreferences.setMockInitialValues({});
      final host = StopRuntimeHost()..ownsProcess = true;
      host.fail = fail;
      host.gate = Completer<void>();
      final c = await controller(host);
      final pending = c.stop();
      final status = c.status;
      c.dispose();
      host.gate!.complete();
      await pending;
      expect(c.status, status);
      expect(c.error, isNull);
    });
  }

  test('Prepare failures are private, terminal and retryable', () async {
    SharedPreferences.setMockInitialValues({});
    final host = PrepareRuntimeHost();
    final c = await controller(host);
    addTearDown(c.dispose);
    await c.prepare('/private/python');
    expect(c.error, isNot(contains('PRIVATE_PREPARE')));
    expect(c.error, isNot(contains('/private/')));
    expect(c.error, contains('Python'));
    expect(c.error, contains('retry'));
    expect(c.status, contains('failed'));
    expect(c.status, isNot(contains('Checking')));
    expect(c.busy, isFalse);
    expect(host.downloads, 0);
    expect(host.ownsProcess, isFalse);
    host.fail = false;
    await c.prepare('/python');
    expect(c.error, isNull);
    expect(c.status, contains('helper ready'));
    expect(host.preparations, 2);
  });

  test('Prepare excludes duplicates and ignores disposed completion', () async {
    SharedPreferences.setMockInitialValues({});
    final host = PrepareRuntimeHost()..fail = false;
    host.gate = Completer<void>();
    final c = await controller(host);
    final pending = c.prepare('/python');
    expect(c.busy, isTrue);
    await c.prepare('/other');
    expect(host.preparations, 1);
    c.dispose();
    host.gate!.complete();
    await pending;
    expect(c.status, isNot(contains('helper ready')));
  });

  for (final python in [false, true]) {
    test(
      '${python ? 'Python' : 'model folder'} picker errors are private and retryable',
      () async {
        SharedPreferences.setMockInitialValues({});
        final host = PickerRuntimeHost();
        final c = await controller(host);
        addTearDown(c.dispose);
        Future<String?> pick() =>
            python ? c.choosePython() : c.chooseDirectory();
        expect(await pick(), isNull);
        expect(c.error, isNot(contains('PRIVATE_PICKER_SENTINEL')));
        expect(c.error, isNot(contains('token=secret')));
        expect(c.error, isNot(contains('/private/')));
        expect(c.error, contains('Try again'));
        expect(c.error, contains(python ? 'Python' : 'model folder'));
        host.fail = false;
        expect(await pick(), python ? '/python' : '/models');
        expect(c.error, isNull);
        host.cancel = true;
        expect(await pick(), isNull);
        expect(c.error, isNull);
        expect(host.downloads, 0);
        expect(host.ownsProcess, isFalse);
        expect(c.setup.modelPath, isEmpty);
      },
    );
  }

  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final managed in [false, true]) {
    test(
      'setup save failure stays private and prevents effects: $managed',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final durable = RuntimeSetupStore.fromPreferences(prefs);
        const previous = RuntimeSetup(python: '/previous');
        await durable.save(previous);
        final before = prefs.getString('studio.runtimeSetup.v1');
        final failing = FailingSetupStore(durable.records);
        final host = FakeRuntimeHost();
        final c = RuntimeSetupController(
          store: failing,
          modelStore: ModelSettingsStore.fromPreferences(prefs),
          host: host,
          connection: connection(
            ready: () => host.ownsProcess,
            path: '/models',
          ),
        );
        addTearDown(c.dispose);
        c.initialize();
        await c.refresh();
        await c.inspect('/models');
        const values = RuntimeSetup(
          python: '/python',
          repository: 'owner/model',
        );
        if (managed) {
          await c.start(values);
        } else {
          await c.download(values);
        }
        expect(c.error, contains('Runtime setup settings could not be saved'));
        expect(c.error, contains('retry'));
        for (final private in [
          'PRIVATE_SETUP_SENTINEL',
          'token=secret',
          '/private/setup',
        ]) {
          expect(c.error, isNot(contains(private)));
        }
        expect(prefs.getString('studio.runtimeSetup.v1'), before);
        expect(c.setup.python, previous.python);
        expect(host.downloads, 0);
        expect(host.ownsProcess, isFalse);
        expect(c.busy, isFalse);
        expect(c.health.ready, isFalse);
        failing.fail = false;
        if (managed) {
          await c.start(values);
          expect(host.ownsProcess, isTrue);
          expect(c.health.ready, isTrue);
          await c.stop();
        } else {
          await c.download(values);
          expect(host.downloads, 1);
        }
        expect(c.error, isNull);
        expect(durable.load().python, values.python);
        expect(c.setup.python, values.python);
      },
    );
  }
  for (final oldReady in [false, true]) {
    test(
      'old connection refresh cannot replace newly connected health: $oldReady',
      () async {
        final response = Completer<http.Response>();
        final entered = Completer<void>();
        var requests = 0;
        final c = await controller(
          FakeRuntimeHost(),
          api: RuntimeConnection(
            client: MockClient((request) {
              requests++;
              if (requests == 1) {
                entered.complete();
                return response.future;
              }
              expect(request.url.port, 9876);
              return Future.value(
                http.Response(
                  jsonEncode({
                    'status': 'ready',
                    'model': 'selected',
                    'phase': 'writing',
                  }),
                  200,
                ),
              );
            }),
          ),
        );
        addTearDown(c.dispose);
        final pending = c.refresh();
        await entered.future;
        await c.connect(
          const LocalModelConfig(
            baseUrl: 'http://127.0.0.1:9876/v1',
            model: 'selected',
          ),
        );
        expect(c.error, isNull);
        expect(c.health.ready, isTrue);
        final verifiedHealth = c.health;
        response.complete(
          http.Response(
            jsonEncode({
              'status': oldReady ? 'ready' : 'error',
              'model': 'old-model',
              'phase': 'idle',
            }),
            200,
          ),
        );
        await pending;
        expect(c.health, same(verifiedHealth));
        expect(c.health.model, 'selected');
        expect(c.health.detail, contains('streaming'));
        expect(c.connectionConfig.baseUrl, 'http://127.0.0.1:9876/v1');
        // Dropping an obsolete result must still release the polling guard.
        await c.refresh();
        expect(requests, 3);
        expect(c.health.model, 'selected');
      },
    );
  }

  for (final oldReady in [true, false]) {
    test(
      'Stop refresh supersedes pending pre-stop health: $oldReady',
      () async {
        final oldResponse = Completer<http.Response>();
        final stoppedResponse = Completer<http.Response>();
        var requests = 0;
        final host = FakeRuntimeHost()..ownsProcess = true;
        final c = await controller(
          host,
          api: RuntimeConnection(
            client: MockClient((_) {
              requests++;
              if (requests == 1) return oldResponse.future;
              return stoppedResponse.future;
            }),
          ),
        );
        addTearDown(c.dispose);
        final pending = c.refresh();
        await Future<void>.delayed(Duration.zero);
        final stopping = c.stop();
        await Future<void>.delayed(Duration.zero);
        expect(host.ownsProcess, isFalse);
        expect(
          requests,
          2,
          reason: 'Stop must check current health immediately',
        );
        oldResponse.complete(
          http.Response(
            jsonEncode({
              'status': oldReady ? 'ready' : 'error',
              'model': 'obsolete',
            }),
            200,
          ),
        );
        await pending;
        expect(c.health.model, isNot('obsolete'));
        await c.refresh();
        expect(
          requests,
          2,
          reason: 'Obsolete completion must retain newer poll guard',
        );
        stoppedResponse.complete(
          http.Response(
            jsonEncode({'status': 'error', 'model': 'stopped'}),
            200,
          ),
        );
        await stopping;
        expect(c.health.ready, isFalse);
        expect(c.health.model, 'stopped');
        await c.refresh();
        expect(requests, 3);
      },
    );
  }

  test('failed Stop leaves current pending health check valid', () async {
    final response = Completer<http.Response>();
    var requests = 0;
    final c = await controller(
      FakeRuntimeHost(),
      api: RuntimeConnection(
        client: MockClient((_) {
          requests++;
          return response.future;
        }),
      ),
    );
    addTearDown(c.dispose);
    final pending = c.refresh();
    await Future<void>.delayed(Duration.zero);
    await c.stop();
    expect(c.error, contains('retry'));
    await c.refresh();
    expect(requests, 1);
    response.complete(
      http.Response(jsonEncode({'status': 'ready', 'model': 'external'}), 200),
    );
    await pending;
    expect(c.health.ready, isTrue);
    expect(c.health.model, 'external');
    await c.refresh();
    expect(requests, 2);
  });

  test('pending refresh publishes when connection remains current', () async {
    final response = Completer<http.Response>();
    final entered = Completer<void>();
    final c = await controller(
      FakeRuntimeHost(),
      api: RuntimeConnection(
        client: MockClient((_) {
          entered.complete();
          return response.future;
        }),
      ),
    );
    addTearDown(c.dispose);
    final pending = c.refresh();
    await entered.future;
    response.complete(
      http.Response(
        jsonEncode({
          'status': 'ready',
          'model': 'current-model',
          'phase': 'thinking',
        }),
        200,
      ),
    );
    await pending;
    expect(c.health.ready, isTrue);
    expect(c.health.model, 'current-model');
    expect(c.health.detail, contains('processing'));
  });

  test('Connect does not publish a dispatched save after disposal', () async {
    final prefs = await SharedPreferences.getInstance();
    final ordinary = ModelSettingsStore.fromPreferences(prefs);
    final delayed = PendingConnectionStore(ordinary.records);
    final c = RuntimeSetupController(
      store: RuntimeSetupStore.fromPreferences(prefs),
      modelStore: delayed,
      host: FakeRuntimeHost(),
      connection: connection(ready: () => true),
    );
    final status = c.status;
    final initialConnection = c.connectionConfig;
    final pending = c.connect(const LocalModelConfig(model: 'Qwen3.5-9B'));
    await delayed.entered.future;
    c.dispose();
    delayed.release.complete();
    await pending;
    // A dispatched durable write is allowed to finish; closed UI stays unchanged.
    expect(ordinary.load().model, 'Qwen3.5-9B');
    expect(c.connectionConfig, same(initialConnection));
    expect(c.status, status);
    expect(c.health.ready, isFalse);
  });

  for (final closed in [true, false]) {
    test('late Connect health respects setup disposal: $closed', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = ModelSettingsStore.fromPreferences(prefs);
      await store.save(
        const LocalModelConfig(model: 'previous', chatOutputTokens: 512),
      );
      final response = Completer<http.Response>();
      final entered = Completer<void>();
      final c = await controller(
        FakeRuntimeHost(),
        api: RuntimeConnection(
          client: MockClient((_) {
            entered.complete();
            return response.future;
          }),
        ),
      );
      const selected = LocalModelConfig(model: 'selected');
      final pending = c.connect(selected);
      await entered.future;
      final status = c.status;
      final initialConnection = c.connectionConfig;
      if (closed) c.dispose();
      // Preserve settings changed during health verification for live requests.
      await store.save(
        const LocalModelConfig(model: 'previous', chatOutputTokens: 1024),
      );
      response.complete(
        http.Response(
          jsonEncode({'status': 'ready', 'model': 'selected'}),
          200,
        ),
      );
      await pending;
      expect(store.load().model, closed ? 'previous' : 'selected');
      expect(store.load().chatOutputTokens, 1024);
      if (closed) {
        expect(c.connectionConfig, same(initialConnection));
        expect(c.status, status);
        expect(c.health.ready, isFalse);
      } else {
        expect(c.connectionConfig.model, 'selected');
        expect(c.health.ready, isTrue);
        c.dispose();
      }
    });
  }

  for (final key in ['studio.runtimeSetup.v1', 'studio.localModel.v1']) {
    test(
      'saved settings load diagnostics omit private content for $key',
      () async {
        const damaged = 'PRIVATE_SETTINGS_SENTINEL /private/model token=secret';
        SharedPreferences.setMockInitialValues({key: damaged});
        final prefs = await SharedPreferences.getInstance();
        final c = await controller(FakeRuntimeHost());
        addTearDown(c.dispose);
        c.initialize();
        await c.refresh();
        expect(c.error, contains('Saved runtime settings could not be loaded'));
        expect(c.error, contains('Restore valid settings'));
        expect(c.error, isNot(contains('PRIVATE_SETTINGS_SENTINEL')));
        expect(c.error, isNot(contains('token=secret')));
        expect(prefs.getString(key), damaged);
      },
    );
  }

  testWidgets('damaged settings show private recovery guidance in setup', (
    tester,
  ) async {
    const damaged = 'PRIVATE_SETTINGS_SENTINEL token=secret';
    SharedPreferences.setMockInitialValues({'studio.runtimeSetup.v1': damaged});
    final c = await controller(FakeRuntimeHost());
    await tester.pumpWidget(
      MaterialApp(home: RuntimeSetupScreen(controller: c)),
    );
    await tester.pump();
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Restore valid settings'), findsOneWidget);
    expect(find.textContaining('PRIVATE_SETTINGS_SENTINEL'), findsNothing);
    expect(find.textContaining('token=secret'), findsNothing);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'studio.runtimeSetup.v1',
      ),
      damaged,
    );
    await tester.pumpWidget(const SizedBox());
  });

  test('setup probe omits private output and bounds responses', () async {
    for (final outcome in ['success', 'error', 'large', 'stop', 'dispose']) {
      final probe = SetupProbe();
      final c = await controller(
        FakeRuntimeHost(),
        createProvider: (_) => probe,
      );
      final pending = c.test(const LocalModelConfig());
      expect(c.testing, isTrue);
      if (outcome == 'error') {
        probe.output.addError(StateError('PRIVATE_PROMPT'));
      } else if (outcome == 'stop') {
        c.stopTest();
        probe.output.add('PRIVATE_PROMPT');
      } else if (outcome == 'dispose') {
        c.dispose();
      } else {
        probe.output.add(
          outcome == 'large' ? 'PRIVATE_PROMPT' * 400 : 'PRIVATE_PROMPT',
        );
        await probe.output.close();
      }
      await pending;
      expect(c.status, isNot(contains('PRIVATE_PROMPT')));
      if (outcome != 'dispose') {
        expect(
          c.status,
          contains(
            outcome == 'success'
                ? 'completed'
                : outcome == 'large'
                ? 'text limit'
                : outcome == 'stop'
                ? 'stopped'
                : 'failed',
          ),
        );
        c.dispose();
      }
      expect(c.busy, isFalse);
      expect(probe.cancellations, 1);
      if (!probe.output.isClosed) await probe.output.close();
    }
  });
  testWidgets('setup probe exposes stop and enforces deadline', (tester) async {
    final probe = SetupProbe();
    final c = await controller(
      FakeRuntimeHost(supported: false),
      createProvider: (_) => probe,
    );
    await tester.pumpWidget(
      MaterialApp(home: RuntimeSetupScreen(controller: c)),
    );
    final pending = c.test(const LocalModelConfig());
    await tester.pump();
    expect(find.text('Stop test'), findsOneWidget);
    expect(find.text(RuntimeSetupController.requestLimits), findsOneWidget);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(c.status, contains('timed out'));
    await pending;
    expect(c.busy, isFalse);
    await tester.pumpWidget(const SizedBox());
    unawaited(probe.output.close());
  });
  test(
    'parses HF IDs/URLs and HTTPS Git, rejects credentials and shell input',
    () {
      expect(ModelRepository.parse('Qwen/Qwen3.5-9B').huggingFace, true);
      expect(
        ModelRepository.parse('https://huggingface.co/Qwen/Qwen3.5-9B.git')
            .location,
        'Qwen/Qwen3.5-9B',
      );
      expect(
        ModelRepository.parse('https://github.com/team/model.git').name,
        'model',
      );
      for (final input in [
        'file:///tmp/model',
        'https://user:secret@host/team/model',
        'owner/model;echo bad',
        'https://host/a/..',
        'git@github.com:a/b',
      ]) {
        expect(
          () => ModelRepository.parse(input),
          throwsFormatException,
          reason: input,
        );
      }
    },
  );
  test('using downloaded files never invokes network download', () async {
    final host = FakeRuntimeHost();
    final c = await controller(host);
    await c.inspect('/models');
    expect(c.selected?.supported, true);
    expect(host.downloads, 0);
    c.dispose();
  });
  test('download is explicit and validated before selection', () async {
    final host = FakeRuntimeHost();
    final c = await controller(host);
    expect(host.downloads, 0);
    await c.download(
      const RuntimeSetup(
        repository: 'Qwen/Qwen3.5-9B',
        downloadParent: '/models',
      ),
    );
    expect(host.downloads, 1);
    expect(c.selected?.path, '/models/Qwen3.5-9B');
    c.dispose();
  });
  test(
    'startup saves chat settings only after matching runtime is ready',
    () async {
      final host = FakeRuntimeHost();
      final c = await controller(
        host,
        api: connection(ready: () => host.ownsProcess, path: '/models'),
      );
      await c.inspect('/models');
      await c.start(const RuntimeSetup(python: '/python'));
      expect(c.error, isNull);
      expect(c.health.ready, true);
      expect(
        ModelSettingsStore.fromPreferences(
          await SharedPreferences.getInstance(),
        ).load().model,
        'Qwen3.5-9B',
      );
      await c.stop();
      expect(host.stops, 1);
      c.dispose();
    },
  );
  test('Stop during startup revalidation prevents a later launch', () async {
    final host = DelayedStartupHost();
    final c = await controller(host);
    await c.inspect('/models');
    host.scanGate = Completer<void>();
    final pending = c.start(const RuntimeSetup(python: '/python'));
    await host.entered.future;
    await c.stop();
    host.scanGate!.complete();
    await pending;
    expect(host.launches, 0);
    expect(c.status, 'Managed runtime stopped.');
    expect(c.error, isNull);
    expect(c.busy, isFalse);
    c.dispose();
  });

  for (final dispose in [false, true]) {
    test(
      'late cancelled launch cleanup failure respects privacy and disposal: $dispose',
      () async {
        SharedPreferences.setMockInitialValues({});
        final host = CancelledLaunchHost()..launchGate = Completer<void>();
        final c = await controller(host);
        await c.inspect('/models');
        final selected = c.selected;
        final prefs = await SharedPreferences.getInstance();
        final before = prefs.getString('studio.localModel.v1');
        final pending = c.start(const RuntimeSetup(python: '/python'));
        await host.entered.future;
        await c.stop();
        expect(c.status, 'Managed runtime stopped.');
        host.stopGate = Completer<void>();
        host.launchGate!.complete();
        await host.stopping.future;
        final status = c.status;
        if (dispose) c.dispose();
        host.stopGate!.complete();
        await pending;
        expect(c.busy, isFalse);
        expect(host.ownsProcess, isTrue);
        expect(c.selected, same(selected));
        expect(prefs.getString('studio.localModel.v1'), before);
        final diagnostics = '${c.error} ${c.status} ${c.logs.join(' ')}';
        expect(diagnostics, isNot(contains('PRIVATE_CLEANUP')));
        expect(diagnostics, isNot(contains('/private/')));
        if (dispose) {
          expect(c.status, status);
          expect(c.error, isNull);
        } else {
          expect(c.status, 'Managed runtime stop failed.');
          expect(c.error, contains('retry Stop'));
          host.failStop = false;
          await c.stop();
          expect(c.error, isNull);
          expect(c.status, 'Managed runtime stopped.');
          expect(host.ownsProcess, isFalse);
          expect(host.stops, 1);
          c.dispose();
        }
      },
    );
  }

  test('late cancelled launch is still cleaned up after disposal', () async {
    SharedPreferences.setMockInitialValues({});
    final host = CancelledLaunchHost()
      ..launchGate = Completer<void>()
      ..failStop = false;
    final c = await controller(host);
    await c.inspect('/models');
    final pending = c.start(const RuntimeSetup(python: '/python'));
    await host.entered.future;
    await c.stop();
    final status = c.status;
    c.dispose();
    host.launchGate!.complete();
    await pending;
    expect(host.ownsProcess, isFalse);
    expect(host.stops, 1);
    expect(c.status, status);
    expect(c.error, isNull);
  });

  test('Stop cleans up a managed launch that completes late', () async {
    final host = DelayedStartupHost()..launchGate = Completer<void>();
    final c = await controller(host);
    await c.inspect('/models');
    final pending = c.start(const RuntimeSetup(python: '/python'));
    await host.entered.future;
    await c.stop();
    host.launchGate!.complete();
    await pending;
    expect(host.launches, 1);
    expect(host.stops, 1);
    expect(host.ownsProcess, isFalse);
    expect(c.status, 'Managed runtime stopped.');
    expect(c.error, isNull);
    c.dispose();
  });

  test(
    'late ready health cannot publish or save after Stop or disposal',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = ModelSettingsStore.fromPreferences(prefs);
      for (final dispose in [false, true]) {
        await settings.save(
          const LocalModelConfig(model: 'previous', chatOutputTokens: 512),
        );
        final before = prefs.getString('studio.localModel.v1');
        final host = FakeRuntimeHost();
        final entered = Completer<void>();
        final release = Completer<void>();
        var calls = 0;
        final c = await controller(
          host,
          api: RuntimeConnection(
            client: MockClient((_) async {
              if (calls++ == 0) {
                entered.complete();
                await release.future;
                return http.Response(
                  jsonEncode({
                    'status': 'ready',
                    'model': 'Qwen3.5-9B',
                    'model_path': '/models',
                  }),
                  200,
                );
              }
              return http.Response(jsonEncode({'status': 'loading'}), 200);
            }),
          ),
        );
        await c.inspect('/models');
        final pending = c.start(const RuntimeSetup(python: '/python'));
        await entered.future;
        if (dispose) {
          c.dispose();
        } else {
          await c.stop();
        }
        final status = c.status;
        release.complete();
        await pending;
        expect(prefs.getString('studio.localModel.v1'), before);
        expect(c.status, status);
        expect(c.health.ready, isFalse);
        expect(c.error, isNull);
        expect(c.busy, isFalse);
        if (!dispose) c.dispose();
      }
    },
  );

  test(
    'runtime exit during health reports failure instead of loading',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = ModelSettingsStore.fromPreferences(prefs);
      await settings.save(const LocalModelConfig(model: 'previous'));
      final before = prefs.getString('studio.localModel.v1');
      for (final status in ['loading', 'ready']) {
        final host = FakeRuntimeHost();
        final entered = Completer<void>();
        final release = Completer<void>();
        final c = await controller(
          host,
          api: RuntimeConnection(
            client: MockClient((_) async {
              entered.complete();
              await release.future;
              return http.Response(
                jsonEncode({
                  'status': status,
                  'model': 'Qwen3.5-9B',
                  'model_path': '/models',
                }),
                200,
              );
            }),
          ),
        );
        await c.inspect('/models');
        final pending = c.start(const RuntimeSetup(python: '/python'));
        await entered.future;
        host.ownsProcess = false;
        release.complete();
        await pending;
        expect(c.error, contains('Runtime exited before becoming ready'));
        expect(c.health.ready, isFalse);
        expect(c.busy, isFalse);
        expect(prefs.getString('studio.localModel.v1'), before);
        c.dispose();
      }
    },
  );

  test(
    'reconnect preserves latest durable ceiling after health verification',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = ModelSettingsStore.fromPreferences(prefs);
      await settings.save(const LocalModelConfig(chatOutputTokens: 512));
      final entered = Completer<void>();
      final release = Completer<void>();
      final c = await controller(
        FakeRuntimeHost(),
        api: RuntimeConnection(
          client: MockClient((_) async {
            entered.complete();
            await release.future;
            return http.Response(
              jsonEncode({'status': 'ready', 'model': 'new'}),
              200,
            );
          }),
        ),
      );
      final pending = c.connect(const LocalModelConfig(model: 'new'));
      await entered.future;
      await settings.save(const LocalModelConfig(chatOutputTokens: 1024));
      release.complete();
      await pending;
      expect(c.error, isNull);
      expect(settings.load().model, 'new');
      expect(settings.load().chatOutputTokens, 1024);
      expect(c.connectionConfig.chatOutputTokens, 1024);
      c.dispose();
    },
  );

  for (final managed in [false, true]) {
    test(
      'connection save failure stays private and recoverable: $managed',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final durable = ModelSettingsStore.fromPreferences(prefs);
        await durable.save(
          const LocalModelConfig(model: 'previous', chatOutputTokens: 512),
        );
        final before = prefs.getString('studio.localModel.v1');
        final failing = FailingConnectionStore(durable.records);
        final host = FakeRuntimeHost();
        final c = RuntimeSetupController(
          store: RuntimeSetupStore.fromPreferences(prefs),
          modelStore: failing,
          host: host,
          connection: connection(
            ready: () => !managed || host.ownsProcess,
            path: '/models',
          ),
        );
        addTearDown(c.dispose);
        if (managed) {
          await c.inspect('/models');
          await c.start(const RuntimeSetup(python: '/python'));
        } else {
          await c.connect(const LocalModelConfig());
        }
        expect(c.error, contains('Connection settings could not be saved'));
        expect(c.error, contains('retry'));
        for (final private in [
          'PRIVATE_SAVE_SENTINEL',
          'token=secret',
          '/private/record',
        ]) {
          expect(c.error, isNot(contains(private)));
        }
        expect(c.status, isNot(contains('Project chat now uses')));
        expect(c.status, isNot(startsWith('Connected.')));
        expect(c.health.ready, isFalse);
        expect(c.busy, isFalse);
        expect(prefs.getString('studio.localModel.v1'), before);
        expect(
          c.connectionConfig.chatOutputTokens,
          LocalModelConfig.defaultChatOutputTokens,
        );
        if (managed) {
          expect(host.ownsProcess, isTrue);
          await c.stop();
          expect(host.ownsProcess, isFalse);
          expect(host.stops, 1);
        }
        await durable.save(
          const LocalModelConfig(model: 'previous', chatOutputTokens: 1024),
        );
        failing.fail = false;
        if (managed) {
          await c.start(const RuntimeSetup(python: '/python'));
        } else {
          await c.connect(const LocalModelConfig());
        }
        expect(c.error, isNull);
        expect(c.health.ready, isTrue);
        expect(durable.load().model, 'Qwen3.5-9B');
        expect(durable.load().chatOutputTokens, 1024);
        expect(c.connectionConfig.chatOutputTokens, 1024);
        if (managed) await c.stop();
      },
    );
  }

  test('managed startup retains saved chat ceiling', () async {
    final prefs = await SharedPreferences.getInstance();
    final settings = ModelSettingsStore.fromPreferences(prefs);
    await settings.save(
      const LocalModelConfig(model: 'old', chatOutputTokens: 512),
    );
    final host = FakeRuntimeHost();
    final c = await controller(
      host,
      api: connection(ready: () => host.ownsProcess, path: '/models'),
    );
    await c.inspect('/models');
    await c.start(const RuntimeSetup(python: '/python'));
    expect(c.error, isNull);
    expect(settings.load().model, 'Qwen3.5-9B');
    expect(settings.load().chatOutputTokens, 512);
    expect(c.connectionConfig.chatOutputTokens, 512);
    await c.stop();
    c.dispose();
  });

  test(
    'corrupt settings block reconnect and startup without writes or launch',
    () async {
      final prefs = await SharedPreferences.getInstance();
      for (final raw in [
        'private-sentinel',
        '{"baseUrl":"http://127.0.0.1:8765/v1","model":"local","chatOutputTokens":0}',
      ]) {
        await prefs.setString('studio.localModel.v1', raw);
        final host = FakeRuntimeHost();
        final c = await controller(host, api: connection(ready: () => true));
        await c.connect(const LocalModelConfig());
        expect(c.error, contains('Restore valid settings'));
        expect(c.error, isNot(contains('private-sentinel')));
        await c.inspect('/models');
        await c.start(const RuntimeSetup(python: '/python'));
        expect(c.error, contains('Restore valid settings'));
        expect(host.ownsProcess, isFalse);
        expect(prefs.getString('studio.localModel.v1'), raw);
        c.dispose();
      }
    },
  );

  test(
    'malformed connect URL omits private parser source without effects',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final settings = ModelSettingsStore.fromPreferences(prefs);
      await settings.save(const LocalModelConfig(model: 'previous'));
      final before = prefs.getString('studio.localModel.v1');
      var requests = 0;
      final c = await controller(
        FakeRuntimeHost(),
        api: RuntimeConnection(
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        ),
      );
      await c.connect(
        const LocalModelConfig(
          baseUrl: 'http://[PRIVATE_CONNECT_SENTINEL token=secret/v1',
        ),
      );
      expect(c.error, contains('Invalid connection settings'));
      expect(c.error, isNot(contains('PRIVATE_CONNECT_SENTINEL')));
      expect(c.error, isNot(contains('token=secret')));
      expect(requests, 0);
      expect(prefs.getString('studio.localModel.v1'), before);
      expect(c.connectionConfig.model, 'Qwen3.5-9B');
      expect(c.busy, isFalse);
      c.dispose();
    },
  );

  testWidgets('malformed connect shows safe actionable guidance', (
    tester,
  ) async {
    final c = await controller(FakeRuntimeHost());
    await tester.pumpWidget(
      MaterialApp(home: RuntimeSetupScreen(controller: c)),
    );
    await tester.pump();
    await c.connect(
      const LocalModelConfig(
        baseUrl: 'http://[PRIVATE_CONNECT_SENTINEL token=secret/v1',
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -2000));
    await tester.pumpAndSettle();
    expect(find.textContaining('Invalid connection settings'), findsOneWidget);
    expect(find.textContaining('PRIVATE_CONNECT_SENTINEL'), findsNothing);
    expect(find.textContaining('token=secret'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  test('connection mismatch cannot overwrite saved model settings', () async {
    final host = FakeRuntimeHost();
    final c = await controller(
      host,
      api: connection(ready: () => true, model: 'Other'),
    );
    await c.connect(const LocalModelConfig(model: 'Desired'));
    expect(c.error, contains('No ready runtime'));
    expect(
      ModelSettingsStore.fromPreferences(await SharedPreferences.getInstance())
          .load()
          .model,
      'Qwen3.5-9B',
    );
    await c.stop();
    expect(host.stops, 0);
    c.dispose();
  });
  test(
    'local model validation detects missing shards and unsupported models',
    () async {
      final root = await Directory.systemTemp.createTemp('asg-model-test-');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/config.json').writeAsString(
        jsonEncode({
          'architectures': ['Qwen3_5ForConditionalGeneration'],
        }),
      );
      final host = NativeRuntimeHost();
      expect((await host.scan(root.path)).single.supported, false);
      await File('${root.path}/model.safetensors')
          .writeAsBytes(List.filled(1024, 0));
      await File('${root.path}/tokenizer.json').writeAsString('{}');
      await File('${root.path}/tokenizer_config.json').writeAsString('{}');
      expect((await host.scan(root.path)).single.supported, true);
      await File('${root.path}/config.json').writeAsString(
        jsonEncode({
          'architectures': ['OtherModel'],
        }),
      );
      expect((await host.scan(root.path)).single.supported, false);
    },
    skip: !Platform.isMacOS,
  );
  for (final metadata in ['config', 'index', 'missing shard']) {
    test('checkpoint $metadata diagnostics omit private metadata', () async {
      final root = await Directory.systemTemp.createTemp(
        'asg-private-metadata-',
      );
      addTearDown(() => root.delete(recursive: true));
      const sentinel = 'PRIVATE_METADATA_SENTINEL_token=secret';
      final config = File('${root.path}/config.json');
      final index = File('${root.path}/model.safetensors.index.json');
      final validConfig = jsonEncode({
        'architectures': ['Qwen3_5ForConditionalGeneration'],
      });
      await config.writeAsString(metadata == 'config' ? sentinel : validConfig);
      if (metadata != 'config') {
        await index.writeAsString(
          metadata == 'index'
              ? sentinel
              : jsonEncode({
                  'weight_map': {'weight': '$sentinel.safetensors'},
                }),
        );
      }
      final before = await config.readAsString();
      final indexBefore = await index.exists()
          ? await index.readAsString()
          : null;
      final candidate = (await ScanningRuntimeHost().scan(root.path)).single;
      expect(candidate.supported, isFalse);
      expect(candidate.path, await root.resolveSymbolicLinks());
      expect(candidate.detail, isNot(contains(sentinel)));
      expect(
        candidate.detail,
        contains(metadata == 'missing shard' ? 'complete' : 'config.json'),
      );
      expect(await config.readAsString(), before);
      if (indexBefore != null) expect(await index.readAsString(), indexBefore);
    });
  }
  testWidgets('landing page has top-right runtime FAB', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      StudioApp(store: StudioStore.fromPreferences(prefs)),
    );
    expect(find.byTooltip('Set up runtime'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.floatingActionButtonLocation, isA<RuntimeFabLocation>());
  });
  testWidgets(
    'health panel omits server identity and does not label loading offline',
    (tester) async {
      final c = await controller(
        FakeRuntimeHost(),
        api: RuntimeConnection(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'status': 'loading',
                'phase': 'private-phase-sentinel',
                'backend': 'private-backend-sentinel',
                'model': 'private-model-sentinel',
              }),
              200,
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(home: RuntimeSetupScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Runtime not ready'), findsOneWidget);
      expect(find.textContaining('model loading'), findsOneWidget);
      expect(find.text('Runtime offline'), findsNothing);
      expect(find.textContaining('sentinel'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('runtime setup remains usable on a narrow viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = await controller(FakeRuntimeHost());
    await tester.pumpWidget(
      MaterialApp(home: RuntimeSetupScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Set up runtime'), findsOneWidget);
    expect(find.text('Find local models'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'unsupported hosts offer connection rather than fake local setup',
    (tester) async {
      final c = await controller(FakeRuntimeHost(supported: false));
      await tester.pumpWidget(
        MaterialApp(home: RuntimeSetupScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Model setup on your Mac'), findsOneWidget);
      expect(find.text('Start selected model'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
