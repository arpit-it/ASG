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
import 'package:asg/services/runtime_connection.dart';
import 'package:asg/services/runtime_host.dart';
import 'package:asg/services/runtime_host_native.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/views/runtime_setup_screen.dart';
import 'package:asg/views/studio_app.dart';
import 'package:asg/views/dashboard.dart';
import 'package:asg/services/studio_store.dart';

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
}) async {
  final prefs = await SharedPreferences.getInstance();
  return RuntimeSetupController(
    store: RuntimeSetupStore.fromPreferences(prefs),
    modelStore: ModelSettingsStore.fromPreferences(prefs),
    host: host,
    connection: api ?? connection(ready: () => false),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
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
  testWidgets('landing page has top-right runtime FAB', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      StudioApp(store: StudioStore.fromPreferences(prefs)),
    );
    expect(find.byTooltip('Set up runtime'), findsOneWidget);
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
    expect(scaffold.floatingActionButtonLocation, isA<RuntimeFabLocation>());
  });
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
