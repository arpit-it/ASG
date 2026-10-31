// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/runtime_capabilities.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/views/runtime_capability_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_setup_test.dart' show ScanningRuntimeHost;
import 'runtime_capabilities_test.dart' as discovery;

void main() {
  test(
    'actual scan sums distinct weights and rejects incomplete footprints',
    () async {
      final root = await Directory.systemTemp.createTemp('asg weight size ');
      addTearDown(() => root.delete(recursive: true));
      await File('${root.path}/config.json').writeAsString(
        jsonEncode({
          'architectures': ['Qwen3_5ForConditionalGeneration'],
        }),
      );
      for (final name in ['tokenizer.json', 'tokenizer_config.json']) {
        await File('${root.path}/$name').writeAsString('{}');
      }
      await File('${root.path}/model.safetensors')
          .writeAsBytes(List.filled(1024, 0));
      final host = ScanningRuntimeHost();
      expect((await host.scan(root.path)).single.weightBytes, 1024);
      await File('${root.path}/second.safetensors')
          .writeAsBytes(List.filled(2048, 0));
      final index = File('${root.path}/model.safetensors.index.json');
      await index.writeAsString(
        jsonEncode({
          'metadata': {'total_size': 999999999},
          'weight_map': {
            'a': 'model.safetensors',
            'b': 'model.safetensors',
            'c': 'second.safetensors',
          },
        }),
      );
      expect((await host.scan(root.path)).single.weightBytes, 3072);
      await File('${root.path}/second.safetensors').delete();
      final rejected = (await host.scan(root.path)).single;
      expect(rejected.supported, isFalse);
      expect(rejected.weightBytes, isNull);
      expect(host.ownsProcess, isFalse);
    },
  );

  test('non-weight index entries never become trusted weight bytes', () async {
    final root = await Directory.systemTemp.createTemp('asg malformed index ');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/config.json').writeAsString(
      jsonEncode({
        'architectures': ['Qwen3_5ForConditionalGeneration'],
      }),
    );
    for (final name in ['tokenizer.json', 'tokenizer_config.json']) {
      await File('${root.path}/$name').writeAsString('{}');
    }
    final index = File('${root.path}/model.safetensors.index.json');
    final host = ScanningRuntimeHost();
    for (final name in [
      'tokenizer.json',
      'tokenizer_config.json',
      'config.json',
      'model.safetensors.index.json',
    ]) {
      await index.writeAsString(
        jsonEncode({
          'weight_map': {'a': name},
        }),
      );
      final candidate = (await host.scan(root.path)).single;
      expect(candidate.supported, isFalse, reason: name);
      expect(candidate.weightBytes, isNull, reason: name);
    }
  });

  test('internal aliases counted once, external links never trusted', () async {
    final root = await Directory.systemTemp.createTemp('asg weight alias ');
    addTearDown(() => root.delete(recursive: true));
    final checkpoint = await Directory('${root.path}/checkpoint').create();
    await File('${checkpoint.path}/config.json').writeAsString(
      jsonEncode({
        'architectures': ['Qwen3_5ForConditionalGeneration'],
      }),
    );
    for (final name in ['tokenizer.json', 'tokenizer_config.json']) {
      await File('${checkpoint.path}/$name').writeAsString('{}');
    }
    await File('${checkpoint.path}/one.safetensors')
        .writeAsBytes(List.filled(1024, 0));
    final alias = Link('${checkpoint.path}/two.safetensors');
    await alias.create('${checkpoint.path}/one.safetensors');
    await File('${checkpoint.path}/model.safetensors.index.json').writeAsString(
      jsonEncode({
        'weight_map': {'a': 'one.safetensors', 'b': 'two.safetensors'},
      }),
    );
    final host = ScanningRuntimeHost();
    expect((await host.scan(checkpoint.path)).single.weightBytes, 1024);
    final external = await File('${root.path}/PRIVATE')
        .writeAsBytes(List.filled(4096, 0));
    await alias.delete();
    await alias.create(external.path);
    final rejected = (await host.scan(checkpoint.path)).single;
    expect(rejected.supported, isFalse);
    expect(rejected.weightBytes, isNull);
    expect(rejected.detail, isNot(contains(external.path)));
    expect(await external.length(), 4096);
    await alias.delete();
    final tokenizer = File('${checkpoint.path}/tokenizer.json');
    await tokenizer.writeAsString(' ' * 1024);
    await alias.create(tokenizer.path);
    final metadataAlias = (await host.scan(checkpoint.path)).single;
    expect(metadataAlias.supported, isFalse);
    expect(metadataAlias.weightBytes, isNull);
    expect(await tokenizer.length(), 1024);
  }, skip: Platform.isWindows);

  testWidgets('selected disk footprint is honest, private and responsive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final bytes in [null, 1024 * 1024 * 1024, 2 * 1024 * 1024 * 1024]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: SingleChildScrollView(
                child: RuntimeCapabilityPanel(
                  report: RuntimeCapabilities.fromJson(discovery.report()),
                  selected: ModelCandidate(
                    path: '/PRIVATE',
                    name: 'model',
                    supported: true,
                    detail: 'PRIVATE',
                    weightBytes: bytes,
                  ),
                  backend: RuntimeBackend.auto,
                ),
              ),
            ),
          ),
        ),
      );
      final size = bytes == null
          ? 'unknown'
          : '${bytes ~/ (1024 * 1024 * 1024)}.0 GiB';
      expect(
        find.text('Selected checkpoint weights on disk: $size.'),
        findsOneWidget,
      );
      expect(find.textContaining('not a model-fit estimate'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });
}
