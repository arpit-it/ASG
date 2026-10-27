import 'dart:async';
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
}) async {
  final prefs = await SharedPreferences.getInstance();
  return RuntimeSetupController(
    store: RuntimeSetupStore.fromPreferences(prefs),
    modelStore: ModelSettingsStore.fromPreferences(prefs),
    host: host,
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
  setUp(() => SharedPreferences.setMockInitialValues({}));
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
    expect(c.error, contains('Not owned'));
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
