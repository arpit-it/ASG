// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_edit_record.dart';
import 'package:asg/models/imported_commit_edit_request.dart';

import 'imported_commit_edit_observation_test.dart'
    show sampleEditRequest, editResult;

void main() {
  test('pending reopen blocks replay; explicit inspection never promotes late success', () {
    final r = sampleEditRequest(), at = DateTime.utc(2026);
    final pending = ImportedCommitEditRecord.empty(r.root).begin(r, at);
    final reopened = ImportedCommitEditRecord.decode(pending.recordJson);
    expect(reopened.needsRecovery, true);
    expect(() => reopened.begin(r, at), throwsStateError);
    final late = reopened.settle(r, editResult(r), at, unconfirmed: true);
    expect(late.lastPrepared, isNull);
    expect(late.latest!.phase, ImportedCommitEditPhase.unconfirmed);
    final ack = late.acknowledge(at);
    expect(ack.lastPrepared, isNull);
    expect(ack.canBegin, true);
    expect(() => ack.settle(r, editResult(r), at), throwsStateError);
  });
  test('later refusal retains the last durably prepared output and immutable history', () {
    final r = sampleEditRequest(), at = DateTime.utc(2026);
    final good = ImportedCommitEditRecord.empty(r.root)
        .begin(r, at)
        .settle(r, editResult(r), at);
    final next = ImportedCommitEditRequest.restore(
      r.requestJson.replaceFirst(
        '"attempt_id":"${r.attemptId}"',
        '"attempt_id":"${'d' * 32}"',
      ),
    );
    final refused = good
        .begin(next, at)
        .settle(next, editResult(next, prepared: false), at);
    expect(refused.lastPrepared!.request.digest, r.digest);
    expect(refused.needsRecovery, true);
    expect(() => refused.attempts.clear(), throwsUnsupportedError);
    expect(
      ImportedCommitEditRecord.decode(refused.recordJson)
          .lastPrepared!
          .request
          .digest,
      r.digest,
    );
  });
  test('unknown duplicate noncanonical and overflow history refuse without truncation', () {
    final r = sampleEditRequest(), at = DateTime.utc(2026);
    final raw = ImportedCommitEditRecord.empty(r.root).begin(r, at).recordJson;
    for (final value in [
      'private',
      '{}',
      '$raw ',
      raw.replaceFirst('{', '{"version":1,'),
      'x' * (ImportedCommitEditRecord.byteLimit + 1),
    ]) {
      expect(
        () => ImportedCommitEditRecord.decode(value),
        throwsFormatException,
      );
    }
    var full = ImportedCommitEditRecord.empty(r.root);
    for (var i = 1; i <= 16; i++) {
      final next = ImportedCommitEditRequest.restore(
        r.requestJson.replaceFirst(
          '"attempt_id":"${r.attemptId}"',
          '"attempt_id":"${i.toRadixString(16).padLeft(32, '0')}"',
        ),
      );
      full = full.begin(next, at).settle(next, editResult(next), at);
    }
    expect(full.canBegin, false);
    expect(() => full.begin(r, at), throwsStateError);
  });
}
