// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/generation_command_result.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> result() => {
  'exitCode': 0,
  'output': 'checked',
  'timedOut': false,
  'outputLimitExceeded': false,
  'cancelled': false,
};

void main() {
  test(
    'maximum escaped output remains durable and flags never imply success',
    () {
      final data = result()..['output'] = '\u0000' * 65536;
      final step = GenerationCommandResult.decode(jsonEncode(data))
          .step('test');
      expect(step.succeeded, isTrue);
      expect(GenerationStep.fromJson(step.toJson()).output, data['output']);
      for (final flag in ['timedOut', 'outputLimitExceeded', 'cancelled']) {
        final failed = GenerationCommandResult.decode(
          jsonEncode({...data, flag: true}),
        ).step('test');
        expect(failed.succeeded, isFalse);
      }
      expect(
        GenerationCommandResult.decode(jsonEncode({...data, 'exitCode': -15}))
            .step('test')
            .succeeded,
        isFalse,
      );
    },
  );

  test(
    'untrusted protocol refuses malformed shape and output without payload',
    () {
      const secret = '/private/model/request-sensitive';
      final invalid = <String>[
        '$secret invalid-json',
        'null',
        '[]',
        '"$secret"',
        jsonEncode({...result(), 'output': secret * 3000}),
        jsonEncode({...result(), 'unknown': secret}),
        jsonEncode({...result(), 'targetedTest': secret}),
        for (final key in result().keys) ...[
          jsonEncode({...result()}..remove(key)),
          jsonEncode({...result(), key: null}),
          jsonEncode({
            ...result(),
            key: [secret],
          }),
        ],
        jsonEncode({...result(), 'exitCode': 0.5}),
        jsonEncode({...result(), 'timedOut': 0}),
      ];
      for (final payload in invalid) {
        expect(
          () => GenerationCommandResult.decode(payload),
          throwsA(
            isA<FormatException>()
                .having((error) => error.source, 'no raw source', isNull)
                .having(
                  (error) => error.toString(),
                  'sanitized',
                  'FormatException: Invalid generation helper result.',
                ),
          ),
        );
      }
    },
  );

  test(
    'named evidence must match requested target and complete base protocol',
    () {
      const target = FlutterTestTarget(
        file: 'test/app_test.dart',
        name: 'works',
      );
      final named = {
        ...result(),
        'targetedTest': {
          'file': target.file,
          'name': target.name,
          'status': 'passed',
          'reason': 'executedExactTest',
        },
      };
      expect(
        GenerationCommandResult.decode(
          jsonEncode(named),
          target: target,
        ).namedTest?.passed,
        isTrue,
      );
      for (final payload in [
        result(),
        {...named, 'output': 12},
        {...named, 'output': 'x' * 65537},
        {...named, 'cancelled': true},
        {...named, 'exitCode': 1},
        {
          ...named,
          'targetedTest': {...named['targetedTest'] as Map, 'name': 'other'},
        },
      ]) {
        expect(
          () => GenerationCommandResult.decode(
            jsonEncode(payload),
            target: target,
          ),
          throwsFormatException,
        );
      }
    },
  );
}
