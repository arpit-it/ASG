// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/candidate_stop_request.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/source_generation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_failure_test.dart' show failure;

CandidateVerificationRun stopRun({
  String dispatch = 'candidate-p-1:3',
  int number = 1,
}) => CandidateVerificationRun(
  number: number,
  startedAt: DateTime.utc(2026),
  snapshot: failure(),
  finished: false,
  dispatchId: dispatch,
);

void main() {
  test('Stop request round-trips immutable intent without extending the journal schema', () {
    final run = stopRun();
    final legacy = jsonEncode(run.toJson());
    final request = CandidateStopRequest.create(
      'p',
      run,
      DateTime.utc(2026, 2),
    );
    final restored = CandidateStopRequest.fromJson(
      jsonDecode(jsonEncode(request.toJson())),
    );
    expect(restored.matches('p', run), isTrue);
    expect(restored.requestedAt, DateTime.utc(2026, 2));
    expect(jsonEncode(run.toJson()), legacy);
    expect(run.toJson().containsKey('cancellationRequested'), isFalse);
  });

  test('progress/outcome changes retain intent but other run and input identities do not', () {
    final run = stopRun();
    final request = CandidateStopRequest.create(
      'p',
      run,
      DateTime.utc(2026, 2),
    );
    CandidateVerificationRun changed({
      String? dispatch,
      int? number,
      DateTime? started,
      bool? finished,
      GeneratedProject? snapshot,
    }) => CandidateVerificationRun(
      number: number ?? run.number,
      startedAt: started ?? run.startedAt,
      snapshot: snapshot ?? run.snapshot,
      finished: finished ?? run.finished,
      dispatchId: dispatch ?? run.dispatchId,
    );
    expect(
      request.matches(
        'p',
        changed(finished: true, snapshot: failure(cancelled: true)),
      ),
      isTrue,
    );
    for (final other in [
      changed(dispatch: 'candidate-p-2:3'),
      changed(number: 2),
      changed(started: DateTime.utc(2026, 1, 2)),
      changed(snapshot: run.snapshot.copy(sdk: '/other-sdk')),
      changed(
        snapshot: GeneratedProject.fromJson({
          ...run.snapshot.toJson(),
          'sources': {'lib/main.dart': 'b' * 64},
        }),
      ),
    ]) {
      expect(request.matches('p', other), isFalse);
    }
    expect(request.matches('other', run), isFalse);
  });

  test(
    'equivalent source ordering and normalized paths preserve input identity',
    () {
      final original = stopRun();
      CandidateVerificationRun withSnapshot(GeneratedProject value) =>
          CandidateVerificationRun(
            number: original.number,
            startedAt: original.startedAt,
            snapshot: value,
            finished: false,
            dispatchId: original.dispatchId,
          );
      final first = withSnapshot(
        GeneratedProject.fromJson({
          ...original.snapshot.toJson(),
          'sources': {'lib/main.dart': 'a' * 64, 'lib/other.dart': 'b' * 64},
        }),
      );
      final reordered = withSnapshot(
        GeneratedProject.fromJson({
          ...first.snapshot.toJson(),
          'sdk': '/sdk/./',
          'sources': {'lib/other.dart': 'b' * 64, 'lib/main.dart': 'a' * 64},
        }),
      );
      final request = CandidateStopRequest.create(
        'p',
        first,
        DateTime.utc(2026, 2),
      );
      expect(request.matches('p', reordered), isTrue);
    },
  );

  test(
    'malformed requests never retain untrusted payloads in parse errors',
    () {
      final data = CandidateStopRequest.create(
        'p',
        stopRun(),
        DateTime.utc(2026, 2),
      ).toJson();
      for (final invalid in [
        null,
        [],
        {...data, 'version': 1.0},
        {...data, 'extra': true},
        {...data, 'runNumber': 0},
        {...data, 'runNumber': true},
        {...data, 'projectId': ''},
        {...data, 'dispatchId': 'candidate-p-1:03'},
        {...data, 'dispatchId': 'task:0'},
        {...data, 'inputFingerprint': 'private payload'},
        {...data, 'requestedAt': 'not a date'},
        {...data, 'startedAt': '2026-01-01T00:00:00+01:00'},
      ]) {
        try {
          CandidateStopRequest.fromJson(invalid);
          fail('Accepted invalid Stop request');
        } on FormatException catch (error) {
          expect(error.source, isNull);
        }
      }
    },
  );
}
