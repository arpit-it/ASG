// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/ask_controller.dart';
import 'package:asg/services/ask_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_controller_test.dart' show AskRecords;

void main() {
  test(
    'real configured local model answers standalone Ask and persists suggestion',
    () async {
      final records = AskRecords();
      final controller = AskController(AskStore(records))..load();
      var streamedUpdates = 0;
      controller.addListener(() {
        if (controller.draft.isNotEmpty) streamedUpdates++;
      });
      final clock = Stopwatch()..start();
      expect(
        await controller.send(
          'In Dart, explain Future versus Stream in two sentences and show a minimal fenced Dart code example. Do not claim you ran it.',
        ),
        isTrue,
      );
      expect(controller.error, isNull);
      expect(controller.messages.length, 2);
      expect(
        controller.messages.last.content.toLowerCase(),
        contains('future'),
      );
      expect(
        controller.messages.last.content.toLowerCase(),
        contains('stream'),
      );
      expect(controller.messages.last.content, contains('```'));
      expect(streamedUpdates, greaterThan(1));
      final saved = controller.messages.last.content;
      controller.dispose();
      final reopened = AskController(AskStore(records))..load();
      expect(reopened.messages.last.content, saved);
      expect(records.values.keys, [AskStore.key]);
      // Bounded metadata only; no response, prompt or endpoint in diagnostics.
      // ignore: avoid_print
      print(
        'Actual Ask MLX smoke: ${clock.elapsedMilliseconds}ms; $streamedUpdates streamed updates; ${saved.length} answer characters; reopened exact saved answer.',
      );
      reopened.dispose();
    },
    skip: !const bool.fromEnvironment('ASG_REAL_INFERENCE'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
