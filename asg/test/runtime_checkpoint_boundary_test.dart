// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'runtime_setup_test.dart' show ScanningRuntimeHost;

void main() {
  for (final metadata in [
    'config.json',
    'model.safetensors.index.json',
    'model.safetensors',
    'tokenizer.json',
    'tokenizer_config.json',
  ]) {
    for (final external in [true, false]) {
      test(
        'scanner ${external ? 'rejects external' : 'allows internal'} $metadata link',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'asg checkpoint boundary ',
          );
          addTearDown(() => root.delete(recursive: true));
          final checkpoint = await Directory('${root.path}/checkpoint')
              .create();
          final other = await Directory('${root.path}/checkpoint-other')
              .create();
          final config = jsonEncode({
            'architectures': ['Qwen3_5ForConditionalGeneration'],
          });
          final index = jsonEncode({
            'weight_map': {'weight': 'model.safetensors'},
          });
          await File('${checkpoint.path}/config.json').writeAsString(config);
          await File('${checkpoint.path}/model.safetensors.index.json')
              .writeAsString(index);
          await File('${checkpoint.path}/model.safetensors')
              .writeAsBytes(List.filled(1024, 0));
          await File('${checkpoint.path}/tokenizer.json').writeAsString('{}');
          await File('${checkpoint.path}/tokenizer_config.json')
              .writeAsString('{}');
          final host = ScanningRuntimeHost();
          expect((await host.scan(checkpoint.path)).single.supported, isTrue);
          final target = File(
            '${external ? other.path : checkpoint.path}/metadata-target',
          );
          final content = await File('${checkpoint.path}/$metadata')
              .readAsBytes();
          await target.writeAsBytes(content);
          final linkPath = '${checkpoint.path}/$metadata';
          await File(linkPath).delete();
          await Link(linkPath).create(target.path);
          final candidate = (await host.scan(checkpoint.path)).single;
          expect(candidate.supported, !external);
          if (external) {
            expect(candidate.detail, contains('checkpoint folder'));
            expect(candidate.detail, isNot(contains(other.path)));
          }
          expect(await target.readAsBytes(), content);
          expect(await Link(linkPath).target(), target.path);
          expect(host.ownsProcess, isFalse);
        },
        skip: Platform.isWindows,
      );
    }
  }
  test(
    'empty scan explains MLX checkpoint metadata without denying MLX support',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'asg empty checkpoint ',
      );
      addTearDown(() => root.delete(recursive: true));
      final host = ScanningRuntimeHost();
      await expectLater(
        host.scan(root.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'guidance',
            allOf(
              contains('MLX'),
              contains('config.json'),
              isNot(contains('MLX runtimes are not yet supported')),
            ),
          ),
        ),
      );
    },
  );
}
