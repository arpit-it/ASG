// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/candidate_recovery_acknowledgement.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/source_generation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_stop_request_test.dart' show stopRun;

CandidateVerificationRun acknowledged(CandidateVerificationRun run) =>
    CandidateVerificationRun(
      number: run.number,
      startedAt: run.startedAt,
      dispatchId: run.dispatchId,
      finished: true,
      snapshot: run.snapshot.copy(phase: SourceGenerationPhase.failed),
    );
CandidateVerificationRun pendingRun() {
  final run = stopRun();
  return CandidateVerificationRun(
    number: run.number,
    startedAt: run.startedAt,
    dispatchId: run.dispatchId,
    finished: false,
    snapshot: run.snapshot.copy(steps: [], pendingOperation: 'resolve'),
  );
}

void main() {
  test('operator action round-trips exact before and after identity without changing runs', () {
    final before = pendingRun();
    final after = acknowledged(before);
    final raw = jsonEncode(before.toJson());
    final action = CandidateRecoveryAcknowledgement.create(
      'p',
      before,
      after,
      DateTime.utc(2026, 2),
    );
    final restored = CandidateRecoveryAcknowledgement.fromJson(
      jsonDecode(jsonEncode(action.toJson())),
    );
    expect(restored.matches('p', after), isTrue);
    expect(restored.matches('other', after), isFalse);
    expect(restored.matches('p', before), isFalse);
    expect(restored.beforeFingerprint, isNot(restored.afterFingerprint));
    expect(restored.acknowledgedAt, DateTime.utc(2026, 2));
    expect(jsonEncode(before.toJson()), raw);
  });
  test('changed run or outcome cannot reuse acknowledgement', () {
    final before = pendingRun();
    final after = acknowledged(before);
    final action = CandidateRecoveryAcknowledgement.create(
      'p',
      before,
      after,
      DateTime.utc(2026),
    );
    final changed = CandidateVerificationRun(
      number: after.number,
      startedAt: after.startedAt,
      dispatchId: after.dispatchId,
      finished: true,
      snapshot: after.snapshot.copy(error: 'changed'),
    );
    expect(action.matches('p', changed), isFalse);
    expect(
      () => CandidateRecoveryAcknowledgement.create(
        'p',
        before,
        changed,
        DateTime.utc(2026),
      ),
      throwsFormatException,
    );
    expect(
      () => CandidateRecoveryAcknowledgement.create(
        'p',
        after,
        after,
        DateTime.utc(2026),
      ),
      throwsFormatException,
    );
  });
  test('malformed metadata refuses with no private parser source', () {
    final before = pendingRun();
    final good = CandidateRecoveryAcknowledgement.create(
      'p',
      before,
      acknowledged(before),
      DateTime.utc(2026),
    ).toJson();
    for (final change in [
      {'version': 1.0},
      {'dispatchId': 'private:0'},
      {'acknowledgedAt': 'not a date private token'},
      {'afterFingerprint': 'private'},
      {'runNumber': false},
      {'extra': 'private'},
    ]) {
      try {
        CandidateRecoveryAcknowledgement.fromJson({...good, ...change});
        fail('Invalid metadata accepted');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect('$error', isNot(contains('private')));
      }
    }
  });
}
