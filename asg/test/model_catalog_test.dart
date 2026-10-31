// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/models/model_catalog.dart';
import 'package:asg/services/model_catalog_service.dart';
import 'package:asg/controllers/model_catalog_controller.dart';
import 'package:asg/controllers/runtime_setup_controller.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/services/runtime_connection.dart';
import 'package:asg/views/model_catalog_screen.dart';
import 'package:asg/views/runtime_setup_screen.dart';

import 'runtime_setup_test.dart' show FakeRuntimeHost;

final entry = codingModelCatalog.first;
final now = DateTime.utc(2026, 10, 28);
final revision = 'a' * 40;
const host = ModelHardware(
  appleSilicon: true,
  memoryBytes: 36 * gib,
  availableBytes: 24 * gib,
  detail: 'Apple Silicon',
);
Map<String, Object?> api({String? repo, String? sha}) => {
  'id': repo ?? entry.repository,
  'sha': sha ?? revision,
  'cardData': {'license': 'apache-2.0'},
  'siblings': [
    {'rfilename': 'config.json', 'size': 100},
    {'rfilename': 'tokenizer.json', 'size': 200},
    {'rfilename': 'model.safetensors', 'size': 5 * gib},
  ],
};
Map<String, Object?> config({
  String architecture = 'Qwen3_5ForConditionalGeneration',
  int bits = 4,
}) => {
  'architectures': [architecture],
  'quantization': {'bits': bits, 'group_size': 64},
};
http.Response response(Object? value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);
ModelCatalogMetadata metadata({
  int bytes = 5 * gib,
  String architecture = 'Qwen3_5ForConditionalGeneration',
  int bits = 4,
}) => ModelCatalogMetadata(
  revision: revision,
  license: 'apache-2.0',
  architecture: architecture,
  bits: bits,
  mlxFormat: true,
  weightBytes: bytes,
  downloadBytes: bytes + 300,
  checkedAt: now,
);
ModelCatalogService service({
  Map<String, Object?>? modelApi,
  Map<String, Object?>? modelConfig,
}) => ModelCatalogService(
  client: MockClient(
    (r) async => response(
      r.url.path.startsWith('/api/')
          ? modelApi ?? api()
          : modelConfig ?? config(),
    ),
  ),
  now: () => now,
);

class WidgetCatalogService extends ModelCatalogService {
  @override
  Future<ModelCatalogMetadata> check(ModelCatalogEntry entry) async =>
      metadata(bytes: entry.repository.contains('27B') ? 22 * gib : 5 * gib);
  @override
  void close() {}
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

class PreferredCatalogService extends ModelCatalogService {
  PreferredCatalogService(this.values);
  final Map<String, ModelCatalogMetadata?> values;
  @override
  Future<ModelCatalogMetadata> check(ModelCatalogEntry entry) async {
    final value = values[entry.repository];
    if (value == null) throw const ModelCatalogFailure('Offline');
    return value;
  }
}

class PendingPreferredService extends ModelCatalogService {
  final gate = Completer<ModelCatalogMetadata>();
  int calls = 0;
  @override
  Future<ModelCatalogMetadata> check(ModelCatalogEntry entry) {
    calls++;
    return gate.future;
  }
}

void main() {
  test('opening observes current model without public metadata checks and refresh clears stale identity', () async {
    var fail = false;
    final service = PreferredCatalogService({});
    final c = ModelCatalogController(
      service: service,
      probe: () async => const ModelHardware(
        appleSilicon: true,
        memoryBytes: 36 * gib,
        availableBytes: 0,
      ),
      inspectRunning: () async {
        if (fail) throw StateError('PRIVATE');
        return const RunningCatalogModel('Qwen3.8-27B-4bit');
      },
    );
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.runningEntry?.name, 'Qwen3.8 27B · 4-bit');
    expect(c.preferredRunningEntry, c.runningEntry);
    expect(c.metadata(c.runningEntry!), isNull);
    expect(c.entries, isEmpty);
    fail = true;
    await c.initialize();
    expect(c.runningEntry, isNull);
    expect(c.preferredRunningEntry, isNull);
    expect(c.hardware.memoryBytes, 36 * gib);
  });
  test('disposed initial runtime observation cannot publish and duplicate initialization is excluded', () async {
    final gate = Completer<RunningCatalogModel?>();
    var calls = 0;
    final c = ModelCatalogController(
      probe: () async => host,
      inspectRunning: () {
        calls++;
        return gate.future;
      },
    );
    final pending = c.initialize();
    await Future<void>.delayed(Duration.zero);
    await c.initialize();
    expect(calls, 1);
    c.dispose();
    gate.complete(const RunningCatalogModel('Qwen3.8-27B-4bit'));
    await pending;
    expect(c.runningEntry, isNull);
  });
  testWidgets(
    'preferred current model is visible on open at narrow enlarged width and refresh can show older active model',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var model = 'Qwen3.8-27B-4bit';
      final c = ModelCatalogController(
        service: PreferredCatalogService({}),
        probe: () async => host,
        inspectRunning: () async => RunningCatalogModel(model),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ModelCatalogScreen(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Preferred model · Currently in use'));
      expect(
        find.text('Currently in use: Qwen3.8 27B · 4-bit'),
        findsOneWidget,
      );
      model = 'Qwen3.5-27B-4bit';
      await reveal(tester, find.text('Refresh current model'));
      await tester.tap(find.text('Refresh current model'));
      await tester.pumpAndSettle();
      expect(c.runningEntry?.name, 'Qwen3.5 27B · 4-bit');
      expect(c.preferredRunningEntry, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'current runtime remains visible without giving any model memory credit',
    () async {
      final repos = ModelCatalogController.preferredRepositories;
      RunningCatalogModel? resident = const RunningCatalogModel(
        'Qwen3.5-27B-4bit',
      );
      final service = PreferredCatalogService({
        for (final repo in repos) repo: metadata(bytes: 16 * gib),
      });
      final c = ModelCatalogController(
        service: service,
        probe: () async => const ModelHardware(
          appleSilicon: true,
          memoryBytes: 36 * gib,
          availableBytes: 2 * gib,
        ),
        inspectRunning: () async => resident,
      );
      addTearDown(c.dispose);
      await c.initialize();
      await c.refreshPreferred();
      expect(c.entries, isEmpty);
      expect(c.runningEntry?.repository, repos[1]);
      expect(c.assessment(c.runningEntry!).fit, ModelFit.memoryPressure);
      expect(
        c
            .assessment(
              codingModelCatalog.firstWhere((e) => e.repository == repos[0]),
            )
            .fit,
        ModelFit.memoryPressure,
      );
      resident = const RunningCatalogModel('private-sentinel');
      await c.refreshPreferred();
      expect(c.entries, isEmpty);
      expect(c.runningEntry, isNull);
      resident = null;
      await c.refreshPreferred();
      expect(c.entries, isEmpty);
    },
  );

  test('resident cannot override incompatible metadata, total budget or failed recheck', () async {
    final repo = ModelCatalogController.preferredRepositories.first;
    for (final value in [
      metadata(bytes: 30 * gib),
      metadata(architecture: 'Other'),
      null,
    ]) {
      final c = ModelCatalogController(
        service: PreferredCatalogService({repo: value}),
        probe: () async => host,
        inspectRunning: () async =>
            const RunningCatalogModel('Qwen3.8-27B-4bit'),
      );
      await c.initialize();
      await c.refreshPreferred();
      expect(c.entries, isEmpty);
      c.dispose();
    }
  });

  test(
    'newer compatible candidate is checked with ordinary pinned metadata gates',
    () async {
      final newer = codingModelCatalog.firstWhere(
        (e) => e.repository.contains('3.8'),
      );
      final s = service(modelApi: api(repo: newer.repository));
      addTearDown(s.close);
      final checked = await s.check(newer);
      expect(checked.runtimeCompatible, isTrue);
      expect(checked.revision, revision);
      final c = ModelCatalogController(
        service: PreferredCatalogService({newer.repository: checked}),
        probe: () async => host,
      );
      addTearDown(c.dispose);
      await c.initialize();
      await c.refreshPreferred();
      expect(c.entries.single.repository, newer.repository);
    },
  );

  test('failed observation clears previous resident snapshot and later retry recovers', () async {
    var fail = false;
    final repo = ModelCatalogController.preferredRepositories.first;
    final c = ModelCatalogController(
      service: PreferredCatalogService({repo: metadata(bytes: 16 * gib)}),
      probe: () async => const ModelHardware(
        appleSilicon: true,
        memoryBytes: 36 * gib,
        availableBytes: 2 * gib,
      ),
      inspectRunning: () async {
        if (fail) throw StateError('private-sentinel');
        return const RunningCatalogModel('Qwen3.8-27B-4bit');
      },
    );
    addTearDown(c.dispose);
    await c.initialize();
    await c.refreshPreferred();
    expect(c.entries, isEmpty);
    expect(c.runningEntry, isNotNull);
    fail = true;
    await c.refreshPreferred();
    expect(c.entries, isEmpty);
    expect(c.hardware.detail, isNot(contains('sentinel')));
    expect(c.runningEntry, isNull);
    fail = false;
    await c.refreshPreferred();
    expect(c.entries, isEmpty);
    expect(c.runningEntry, isNotNull);
  });

  testWidgets('current runtime remains visible when no new load fits', (
    tester,
  ) async {
    final c = ModelCatalogController(
      service: PreferredCatalogService({}),
      probe: () async => const ModelHardware(
        appleSilicon: true,
        memoryBytes: 36 * gib,
        availableBytes: 0,
      ),
      inspectRunning: () async => const RunningCatalogModel('Qwen3.8-27B-4bit'),
    );
    await c.initialize();
    await c.refreshPreferred();
    await tester.pumpWidget(
      MaterialApp(home: ModelCatalogScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    expect(c.entries, isEmpty);
    expect(find.text('Currently in use: Qwen3.8 27B · 4-bit'), findsOneWidget);
    expect(
      find.textContaining(
        'does not verify the loaded revision or memory adequacy',
      ),
      findsOneWidget,
    );
  });

  test(
    'preferred batch excludes duplicate actions and stops after disposal',
    () async {
      final s = PendingPreferredService();
      final c = ModelCatalogController(service: s, probe: () async => host);
      await c.initialize();
      var notifications = 0;
      c.addListener(() => notifications++);
      final pending = c.refreshPreferred();
      await c.refreshPreferred();
      await c.check(entry);
      await c.discover();
      expect(s.calls, 1);
      expect(c.choose(entry), null);
      c.dispose();
      final count = notifications;
      s.gate.complete(metadata());
      await pending;
      expect(s.calls, 1);
      expect(c.entries, isEmpty);
      expect(notifications, count);
    },
  );

  test('preferred selects one model, falls back under pressure and removes stale failures', () async {
    final repositories = ModelCatalogController.preferredRepositories;
    final s = PreferredCatalogService({
      repositories[0]: metadata(bytes: 16 * gib),
      repositories[1]: metadata(),
    });
    final c = ModelCatalogController(service: s, probe: () async => host);
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.entries, isEmpty);
    await c.refreshPreferred();
    expect(c.entries.single.repository, repositories[0]);
    c.search('9B');
    expect(c.entries, isEmpty);
    c.search('');
    s.values[repositories[0]] = metadata(bytes: 22 * gib);
    await c.refreshPreferred();
    expect(c.entries.single.repository, repositories[1]);
    s.values[repositories[1]] = null;
    await c.refreshPreferred();
    expect(c.entries, isEmpty);
    expect(c.error(entry), isNotNull);
  });
  test(
    'preferred excludes unsupported, oversized and unknown device results',
    () async {
      for (final hardware in [
        const ModelHardware(
          appleSilicon: false,
          memoryBytes: 64 * gib,
          availableBytes: 60 * gib,
        ),
        const ModelHardware(appleSilicon: true),
        const ModelHardware(
          appleSilicon: true,
          memoryBytes: 8 * gib,
          availableBytes: 6 * gib,
        ),
        const ModelHardware(appleSilicon: true, memoryBytes: 36 * gib),
      ]) {
        final s = PreferredCatalogService({
          for (final r in ModelCatalogController.preferredRepositories)
            r: metadata(),
        });
        final c = ModelCatalogController(
          service: s,
          probe: () async => hardware,
        );
        await c.initialize();
        await c.refreshPreferred();
        expect(c.entries, isEmpty);
        c.dispose();
      }
      final s = PreferredCatalogService({
        for (final r in ModelCatalogController.preferredRepositories)
          r: metadata(architecture: 'Qwen2ForCausalLM'),
      });
      final c = ModelCatalogController(service: s, probe: () async => host);
      addTearDown(c.dispose);
      await c.initialize();
      await c.refreshPreferred();
      expect(c.entries, isEmpty);
    },
  );

  test(
    'memory estimates include all weights, cache/runtime and OS allowance',
    () {
      final fit = ModelAssessment.assess(host, metadata());
      expect(fit.fit, ModelFit.estimatedFit);
      expect(fit.estimatedBytes, (5 * gib * 1.25).ceil() + 4 * gib);
      expect(
        ModelAssessment.assess(host, metadata(bytes: 30 * gib)).fit,
        ModelFit.exceedsMemory,
      );
      expect(
        ModelAssessment.assess(
          const ModelHardware(appleSilicon: true, memoryBytes: 8 * gib),
          metadata(),
        ).canChoose,
        false,
      );
      expect(
        ModelAssessment.assess(
          const ModelHardware(
            appleSilicon: true,
            memoryBytes: 36 * gib,
            availableBytes: 0,
          ),
          metadata(),
        ).fit,
        ModelFit.memoryPressure,
      );
    },
  );
  test('unknown hardware and unsupported architecture cannot be chosen', () {
    for (final h in [
      const ModelHardware(appleSilicon: false),
      const ModelHardware(appleSilicon: true),
    ]) {
      expect(ModelAssessment.assess(h, metadata()).canChoose, false);
    }
    expect(ModelAssessment.assess(host, null).canChoose, false);
    expect(
      ModelAssessment.assess(
        host,
        metadata(architecture: 'Qwen2ForCausalLM'),
      ).canChoose,
      false,
    );
    expect(ModelAssessment.assess(host, metadata(bits: 8)).canChoose, false);
  });
  test(
    'metadata requests contain no credentials and never fetch weights',
    () async {
      final seen = <http.Request>[];
      final s = ModelCatalogService(
        client: MockClient((r) async {
          seen.add(r);
          return response(r.url.path.startsWith('/api/') ? api() : config());
        }),
        now: () => now,
      );
      addTearDown(s.close);
      final m = await s.check(entry);
      expect(m.downloadBytes, 5 * gib + 300);
      expect(m.checkedAt, now);
      expect(m.revision, revision);
      expect(seen.length, 2);
      expect(
        seen.every(
          (r) =>
              r.method == 'GET' &&
              r.url.host == 'huggingface.co' &&
              !r.headers.keys.any((k) => k.toLowerCase() == 'authorization'),
        ),
        true,
      );
      expect(seen.last.url.path, contains('/resolve/$revision/config.json'));
      expect(seen.any((r) => r.url.path.endsWith('.safetensors')), false);
    },
  );
  test(
    'missing indexed shard is rejected; complete index is pinned and accepted',
    () async {
      for (final shard in ['missing.safetensors', 'model.safetensors']) {
        final doc = api();
        (doc['siblings'] as List).add({
          'rfilename': 'model.safetensors.index.json',
          'size': 20,
        });
        final s = ModelCatalogService(
          client: MockClient(
            (r) async => response(
              r.url.path.startsWith('/api/')
                  ? doc
                  : r.url.path.endsWith('index.json')
                  ? {
                      'weight_map': {'weight': shard},
                    }
                  : config(),
            ),
          ),
        );
        addTearDown(s.close);
        if (shard.startsWith('missing')) {
          await expectLater(
            s.check(entry),
            throwsA(isA<ModelCatalogFailure>()),
          );
        } else {
          expect((await s.check(entry)).runtimeCompatible, true);
        }
      }
    },
  );
  for (final bad in [
    'docs',
    'missing-tokenizer',
    'size',
    'repo',
    'revision',
    'license',
    'duplicate',
    'traversal',
    'no-index',
  ]) {
    test('reject malformed/incomplete repository: $bad', () async {
      final doc = api();
      final files = doc['siblings'] as List;
      switch (bad) {
        case 'docs':
          files.clear();
          files.add({'rfilename': 'README.md', 'size': 1});
        case 'missing-tokenizer':
          files.removeAt(1);
        case 'size':
          files[2]['size'] = -1;
        case 'repo':
          doc['id'] = 'PRIVATE_WRONG';
        case 'revision':
          doc['sha'] = 'not-a-revision';
        case 'license':
          doc['cardData'] = {'license': '/PRIVATE/path'};
        case 'duplicate':
          files.add(files[2]);
        case 'traversal':
          files[2]['rfilename'] = '../model.safetensors';
        case 'no-index':
          files[2]['rfilename'] = 'shard.safetensors';
      }
      final s = service(modelApi: doc);
      addTearDown(s.close);
      await expectLater(s.check(entry), throwsA(isA<ModelCatalogFailure>()));
    });
  }
  test(
    'unknown registered-source impersonation is rejected before IO',
    () async {
      var calls = 0;
      final s = ModelCatalogService(
        client: MockClient((r) async {
          calls++;
          return response(api());
        }),
      );
      addTearDown(s.close);
      await expectLater(
        s.check(
          const ModelCatalogEntry(
            repository: 'other/PRIVATE',
            name: 'x',
            description: 'x',
            github: '',
          ),
        ),
        throwsA(isA<ModelCatalogFailure>()),
      );
      expect(calls, 0);
    },
  );
  test(
    'oversized and non-JSON metadata fail without raw error leakage',
    () async {
      for (final body in ['x' * (2 * 1024 * 1024 + 1), 'PRIVATE_NOT_JSON']) {
        final s = ModelCatalogService(
          client: MockClient((r) async => http.Response(body, 200)),
        );
        addTearDown(s.close);
        try {
          await s.check(entry);
          fail('Expected rejection');
        } catch (e) {
          expect('$e', isNot(contains('PRIVATE')));
        }
      }
    },
  );
  test(
    'search is explicit, bounded, public and only adds MLX 4-bit candidates',
    () async {
      var calls = 0;
      final s = ModelCatalogService(
        client: MockClient((r) async {
          calls++;
          if (r.url.path == '/api/models') {
            expect(r.url.queryParameters['limit'], '40');
            expect(r.url.queryParameters['author'], 'mlx-community');
            return response([
              {'id': 'mlx-community/Example-Coder-4bit'},
              {'id': 'mlx-community/Example-Coder-8bit'},
            ]);
          }
          return response(
            r.url.path.startsWith('/api/')
                ? api(repo: 'mlx-community/Example-Coder-4bit')
                : config(),
          );
        }),
      );
      addTearDown(s.close);
      expect(calls, 0);
      final found = await s.search('Coder');
      expect(found.length, 1);
      expect((await s.check(found.single)).runtimeCompatible, true);
      await expectLater(
        s.search('https://private/secret'),
        throwsA(isA<ModelCatalogFailure>()),
      );
    },
  );
  test('check retry binds fresh revision and license; failed refresh removes selectable stale metadata', () async {
    var version = 0;
    final s = ModelCatalogService(
      client: MockClient((r) async {
        if (version == 2) throw Exception('PRIVATE_TOKEN');
        final doc = api(sha: version == 0 ? revision : 'b' * 40);
        doc['cardData'] = {'license': version == 0 ? 'apache-2.0' : 'mit'};
        return response(r.url.path.startsWith('/api/') ? doc : config());
      }),
    );
    final c = ModelCatalogController(service: s, probe: () async => host);
    addTearDown(c.dispose);
    await c.initialize();
    await c.check(entry);
    expect(c.choose(entry)?.metadata.revision, revision);
    version = 1;
    await c.check(entry);
    expect(c.choose(entry)?.metadata.revision, 'b' * 40);
    expect(c.metadata(entry)?.license, 'mit');
    version = 2;
    await c.check(entry);
    expect(c.choose(entry), null);
    expect(c.error(entry), isNot(contains('PRIVATE')));
    version = 0;
    await c.check(entry);
    expect(c.choose(entry), isNotNull);
  });
  test('busy exclusion and disposal prevent late result updates', () async {
    final gate = Completer<http.Response>();
    var calls = 0;
    final s = ModelCatalogService(
      client: MockClient((r) {
        calls++;
        return gate.future;
      }),
    );
    final c = ModelCatalogController(service: s, probe: () async => host);
    await c.initialize();
    var notifications = 0;
    c.addListener(() => notifications++);
    final pending = c.check(entry);
    await c.check(codingModelCatalog[1]);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    expect(c.choose(entry), null);
    c.dispose();
    final count = notifications;
    gate.complete(response(api()));
    await pending;
    expect(notifications, count);
    expect(c.metadata(entry), null);
  });
  test('discovery failure retries without losing existing candidates; unsupported filter is explicit', () async {
    var failSearch = true;
    final s = ModelCatalogService(
      client: MockClient((r) async {
        if (r.url.path == '/api/models') {
          if (failSearch) return response({}, 503);
          return response([
            {'id': 'mlx-community/Extra-Coder-4bit'},
          ]);
        }
        return response(
          r.url.path.startsWith('/api/')
              ? api()
              : config(architecture: 'Qwen2ForCausalLM'),
        );
      }),
    );
    final c = ModelCatalogController(service: s, probe: () async => host);
    addTearDown(c.dispose);
    await c.initialize();
    c.showPreferredOnly(false);
    c.search('Coder');
    await c.discover();
    expect(c.searchError, isNotNull);
    expect(c.entries, isNotEmpty);
    failSearch = false;
    await c.discover();
    expect(c.searchError, null);
    expect(
      c.entries.any((e) => e.repository == 'mlx-community/Extra-Coder-4bit'),
      true,
    );
    c.search('9B');
    await c.check(entry);
    expect(c.entries, isEmpty);
    c.showCompatibleOnly(false);
    expect(c.entries, contains(entry));
    expect(c.choose(entry), null);
  });
  test(
    'hardware probe errors remain unknown and cannot enable selection',
    () async {
      final c = ModelCatalogController(
        service: service(),
        probe: () async => throw StateError('PRIVATE_HOST'),
      );
      addTearDown(c.dispose);
      await c.initialize();
      await c.check(entry);
      expect(c.hardware.memoryBytes, null);
      expect(c.choose(entry), null);
      expect(c.hardware.detail, isNot(contains('PRIVATE')));
    },
  );
  test(
    'AWQ/GPTQ and unknown quantization layout never enable MLX selection',
    () async {
      for (final layout in [
        {
          'quantization_config': {
            'bits': 4,
            'group_size': 64,
            'quant_method': 'awq',
          },
        },
        {
          'quantization': {'bits': 4, 'group_size': 0},
        },
        {
          'quantization': {'bits': 4, 'group_size': 64.5},
        },
        {
          'quantization': {'bits': 4, 'group_size': 64, 'quant_method': 'gptq'},
        },
      ]) {
        final cfg = <String, Object?>{
          'architectures': ['Qwen3_5ForConditionalGeneration'],
          ...layout,
        };
        final s = service(modelConfig: cfg);
        addTearDown(s.close);
        final m = await s.check(entry);
        expect(m.mlxFormat, false);
        expect(ModelAssessment.assess(host, m).canChoose, false);
      }
    },
  );
  for (final indexed in [false, true]) {
    test(
      'zero-byte required weights cannot hide behind unrelated weights (indexed: $indexed)',
      () async {
        final doc = api();
        final files = doc['siblings'] as List;
        files[2]['size'] = 0;
        files.add({'rfilename': 'unrelated.safetensors', 'size': gib});
        if (indexed) {
          files.add({'rfilename': 'model.safetensors.index.json', 'size': 20});
        }
        final s = ModelCatalogService(
          client: MockClient(
            (r) async => response(
              r.url.path.startsWith('/api/')
                  ? doc
                  : r.url.path.endsWith('index.json')
                  ? {
                      'weight_map': {'weight': 'model.safetensors'},
                    }
                  : config(),
            ),
          ),
        );
        addTearDown(s.close);
        await expectLater(s.check(entry), throwsA(isA<ModelCatalogFailure>()));
      },
    );
  }
  for (final name in [
    'config.json',
    'tokenizer.json',
    'model.safetensors.index.json',
  ]) {
    test('zero-byte required metadata is rejected: $name', () async {
      final doc = api();
      final files = doc['siblings'] as List;
      if (name.endsWith('index.json')) {
        files.add({'rfilename': name, 'size': 0});
      } else {
        (files.firstWhere((f) => f['rfilename'] == name) as Map)['size'] = 0;
      }
      final s = service(modelApi: doc);
      addTearDown(s.close);
      await expectLater(s.check(entry), throwsA(isA<ModelCatalogFailure>()));
    });
  }
  testWidgets('catalog is readable at narrow width and doubled text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = ModelCatalogController(
      service: WidgetCatalogService(),
      probe: () async => host,
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ModelCatalogScreen(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Preferred models only'));
    await tester.tap(find.text('Preferred models only'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a coding model'), findsOneWidget);
    expect(tester.takeException(), null);
    await reveal(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), '9B');
    await tester.pump();
    await reveal(tester, find.byKey(ValueKey('check-${entry.repository}')));
    await tester.tap(find.byKey(ValueKey('check-${entry.repository}')));
    await tester.pumpAndSettle();
    expect(
      c.metadata(entry),
      isNotNull,
      reason: 'busy=${c.busy}; error=${c.error(entry)}',
    );
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'picker selection fills pinned form without download, runtime switch or persistence',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final runtimeHost = FakeRuntimeHost();
      final store = RuntimeSetupStore.fromPreferences(preferences);
      final runtime = RuntimeSetupController(
        store: store,
        modelStore: ModelSettingsStore.fromPreferences(preferences),
        host: runtimeHost,
        connection: RuntimeConnection(
          client: MockClient((r) async => http.Response('{}', 503)),
        ),
      );
      final c = ModelCatalogController(
        service: WidgetCatalogService(),
        probe: () async => host,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RuntimeSetupScreen(controller: runtime, createCatalog: () => c),
        ),
      );
      await tester.pump();
      final browse = find.text('Browse coding models for this computer');
      await tester.ensureVisible(browse);
      await tester.tap(browse);
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Check preferred models'));
      await tester.tap(find.text('Check preferred models'));
      await tester.pumpAndSettle();
      expect(
        c.metadata(entry),
        isNotNull,
        reason: 'busy=${c.busy}; error=${c.error(entry)}',
      );
      final choose = find.byKey(ValueKey('choose-${entry.repository}'));
      await reveal(tester, choose);
      await tester.tap(choose);
      await tester.pumpAndSettle();
      for (final label in ['Model repository', 'Revision / branch']) {
        final input = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == label,
        );
        await reveal(tester, input);
        expect(
          tester.widget<TextField>(input).controller?.text,
          label == 'Model repository' ? entry.repository : revision,
        );
      }
      expect(runtimeHost.downloads, 0);
      expect(runtimeHost.ownsProcess, false);
      expect(store.load().repository, '');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
