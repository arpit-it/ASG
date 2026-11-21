// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_commit_copy_record.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_copy_observation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_copy_observation_test.dart'
    show copyRequest, copyObservationData;

ImportedCommitCopyObservation copyResult(
  ImportedCommitCopyRequest request, {
  bool prepared = true,
}) => ImportedCommitCopyObservation.fromJson(
  jsonEncode(copyObservationData(request, prepared: prepared)),
  request: request,
);
void main() {
  final at = DateTime.utc(2026);
  test('pending restart blocks replay and manual acknowledgement cannot promote success', () {
    final request = copyRequest();
    final initial = ImportedCommitCopyRecord.empty('/project');
    final pending = initial.begin(request, at);
    final reopened = ImportedCommitCopyRecord.decode(pending.recordJson);
    expect(reopened.needsRecovery, true);
    expect(reopened.canBegin, false);
    expect(reopened.lastPrepared, isNull);
    expect(() => reopened.begin(request, at), throwsStateError);
    final acknowledged = reopened.acknowledge(
      at.add(const Duration(seconds: 1)),
    );
    expect(acknowledged.canBegin, true);
    expect(acknowledged.lastPrepared, isNull);
    expect(acknowledged.latest!.phase, ImportedCommitCopyPhase.pending);
    expect(
      () => acknowledged.settle(
        request,
        copyResult(request),
        at.add(const Duration(seconds: 2)),
      ),
      throwsStateError,
    );
    expect(() => acknowledged.begin(request, at), throwsStateError);
  });
  test('late prepared receipt is unconfirmed recovery evidence and retains old success', () {
    final request = copyRequest();
    final prepared = ImportedCommitCopyRecord.empty('/project')
        .begin(request, at)
        .settle(request, copyResult(request), at);
    final next = ImportedCommitCopyRequest.restore(
      request.requestJson.replaceFirst('a' * 32, 'b' * 32),
    );
    final uncertain = prepared
        .begin(next, at)
        .settle(next, copyResult(next), at, unconfirmed: true);
    expect(uncertain.lastPrepared!.request.digest, request.digest);
    expect(uncertain.latest!.observation!.fingerprint, 'f' * 64);
    expect(uncertain.needsRecovery, true);
    final ack = uncertain.acknowledge(at);
    expect(ack.lastPrepared!.request.digest, request.digest);
    expect(ack.attempts.length, 2);
    expect(
      ImportedCommitCopyRecord.decode(ack.recordJson).recordJson,
      ack.recordJson,
    );
    expect(() => ack.attempts.clear(), throwsUnsupportedError);
  });
  test(
    'refusal and lost receipt retain attempt scope and require inspection',
    () {
      final request = copyRequest();
      final pending = ImportedCommitCopyRecord.empty('/project')
          .begin(request, at);
      final refused = pending.settle(
        request,
        copyResult(request, prepared: false),
        at,
      );
      expect(refused.needsRecovery, true);
      expect(refused.lastPrepared, isNull);
      final lost = pending.settle(request, null, at, unconfirmed: true);
      expect(lost.latest!.observation, isNull);
      expect(lost.latest!.request.destination, '/copies');
      expect(lost.canBegin, false);
    },
  );
  test(
    'bounded append-only retention refuses overflow before a new attempt',
    () {
      var value = ImportedCommitCopyRecord.empty('/project');
      final original = copyRequest();
      for (var i = 1; i <= ImportedCommitCopyRecord.attemptLimit; i++) {
        final nonce = i.toRadixString(16).padLeft(32, '0');
        final request = ImportedCommitCopyRequest.restore(
          original.requestJson.replaceFirst('a' * 32, nonce),
        );
        value = value
            .begin(request, at)
            .settle(request, copyResult(request), at);
      }
      expect(value.attempts.length, 16);
      expect(value.canBegin, false);
      expect(() => value.begin(original, at), throwsStateError);
      expect(
        ImportedCommitCopyRecord.decode(value.recordJson).attempts.length,
        16,
      );
    },
  );
  test(
    'unknown duplicate mismatched and noncanonical histories refuse privately',
    () {
      final request = copyRequest();
      final pending = ImportedCommitCopyRecord.empty('/project')
          .begin(request, at);
      final raw = pending.recordJson;
      for (final data in [
        'private',
        '{}',
        '$raw ',
        raw.replaceFirst('{', '{"version":1,'),
        'x' * (ImportedCommitCopyRecord.byteLimit + 1),
      ]) {
        expect(
          () => ImportedCommitCopyRecord.decode(data),
          throwsFormatException,
        );
      }
      for (final change in <void Function(Map<String, dynamic>)>[
        (d) => d['root'] = '/other',
        (d) => d['version'] = 1.0,
        (d) => d['unknown'] = true,
        (d) => d['attempts'][0]['phase'] = 'prepared',
        (d) => d['attempts'][0]['startedAt'] = 'private',
        (d) => d['attempts'][0]['finishedAt'] = at.toIso8601String(),
        (d) => d['attempts'] = [
          ...d['attempts'] as List,
          ...d['attempts'] as List,
        ],
      ]) {
        final d = jsonDecode(raw) as Map<String, dynamic>;
        change(d);
        expect(
          () => ImportedCommitCopyRecord.decode(jsonEncode(d)),
          throwsFormatException,
        );
      }
    },
  );
}
