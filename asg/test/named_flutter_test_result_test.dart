// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/named_flutter_test_result.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:flutter_test/flutter_test.dart';

const target = FlutterTestTarget(file: 'test/a_test.dart', name: 'literal .*');
Map<String, dynamic> evidence() => {
  'exitCode': 0,
  'timedOut': false,
  'cancelled': false,
  'outputLimitExceeded': false,
  'output': 'PRIVATE_OUTPUT',
  'targetedTest': <String, dynamic>{
    'file': target.file,
    'name': target.name,
    'status': 'passed',
    'reason': 'executedExactTest',
  },
};
void main() {
  test('typed exact result roundtrips without raw output', () {
    final result = NamedFlutterTestResult.fromCommand(evidence(), target);
    expect(result.passed, isTrue);
    expect(result.toJson().toString(), isNot(contains('PRIVATE_OUTPUT')));
    expect(
      NamedFlutterTestResult.fromCommand(result.toJson(), target).passed,
      isTrue,
    );
  });
  test(
    'missing mismatched malformed and contradictory evidence is refused',
    () {
      final variants = <Map<String, dynamic>>[
        {...evidence()}..remove('targetedTest'),
        {...evidence(), 'exitCode': 1},
        {...evidence(), 'timedOut': true},
        {...evidence(), 'cancelled': true},
        {...evidence(), 'outputLimitExceeded': true},
        {...evidence(), 'exitCode': false},
        {...evidence(), 'cancelled': null},
        for (final field in ['file', 'name', 'status', 'reason'])
          {
            ...evidence(),
            'targetedTest': <String, dynamic>{
              ...evidence()['targetedTest'] as Map,
              field: 'invalid',
            },
          },
      ];
      for (final value in variants) {
        expect(
          () => NamedFlutterTestResult.fromCommand(value, target),
          throwsFormatException,
        );
      }
    },
  );
  test('all helper failure reasons remain failures', () {
    for (final reason in [
      'commandFailed',
      'incompleteProtocol',
      'invalidOrIncompleteProtocol',
      'missingOrAmbiguousTest',
    ]) {
      final value = {
        ...evidence(),
        'exitCode': -1,
        'targetedTest': <String, dynamic>{
          ...evidence()['targetedTest'] as Map,
          'status': 'notPassed',
          'reason': reason,
        },
      };
      expect(NamedFlutterTestResult.fromCommand(value, target).passed, isFalse);
    }
  });
}
