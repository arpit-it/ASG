// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/session_proposal_request.dart';
import 'package:flutter_test/flutter_test.dart';

SessionProposalRequest requestMetadata({
  int number = 1,
  Map<String, String>? sources,
}) => SessionProposalRequest(
  number: number,
  projectId: 'project',
  sessionId: 'session',
  boardTaskId: 'Ttest',
  requirementId: 'R1',
  requirementsRevision: 2,
  sessionSha256: 'a' * 64,
  approvalSha256: 'b' * 64,
  workingSha256: 'c' * 64,
  sourceSha256: sources ?? {'lib/main.dart': 'd' * 64},
  modelRequest: const ModelRequestProvenance(
    model: 'Qwen3.8-27B-4bit',
    outputTokens: 4096,
  ),
  startedAt: DateTime.utc(2026, 11, 19),
);

void main() {
  test('canonical detached unresolved metadata cannot restore source or request authority', () {
    final sources = {'lib/main.dart': 'd' * 64};
    final value = requestMetadata(sources: sources);
    final journal = SessionProposalRequestJournal([value]);
    sources['lib/main.dart'] = 'e' * 64;
    expect(value.sourceSha256.values.single, 'd' * 64);
    expect(() => value.sourceSha256.clear(), throwsUnsupportedError);
    expect(() => journal.requests.clear(), throwsUnsupportedError);
    final raw = journal.encode();
    expect(SessionProposalRequestJournal.decode(raw).encode(), raw);
    expect(value.finishedAt, isNull);
    expect(value.returnedSha256, isEmpty);
    for (final forbidden in [
      'endpoint',
      'prompt',
      'summary',
      'before',
      'after',
      'failure',
      'proposal',
    ]) {
      expect(value.toJson().containsKey(forbidden), isFalse);
    }
  });
  test('returned fingerprints and exact reported identity differ from accepted changes', () {
    final original = requestMetadata();
    final returned = original.finish(
      SessionProposalRequestStatus.returnedValidated,
      at: original.startedAt.add(const Duration(seconds: 1)),
      returnedSha256: {'lib/main.dart': 'e' * 64},
      responseModel: 'Qwen3.8-27B-4bit',
    );
    final journal = SessionProposalRequestJournal([returned]);
    expect(
      SessionProposalRequestJournal.decode(journal.encode()).requests.single
          .toJson(),
      returned.toJson(),
    );
    expect(original.status, SessionProposalRequestStatus.reserved);
    expect(
      () => returned.finish(
        SessionProposalRequestStatus.failedLocally,
        at: returned.finishedAt!,
      ),
      throwsStateError,
    );
    for (final outcome in [
      SessionProposalRequestStatus.failedLocally,
      SessionProposalRequestStatus.cancelledLocally,
    ]) {
      final result = original.finish(outcome, at: original.startedAt);
      expect(
        SessionProposalRequestJournal.decode(
          SessionProposalRequestJournal([result]).encode(),
        ).requests.single.status,
        outcome,
      );
    }
  });
  test(
    'rejects ambiguous or noncanonical journal encodings and extra fields',
    () {
      final raw = SessionProposalRequestJournal([requestMetadata()]).encode();
      for (final malformed in [
        ' $raw',
        raw.replaceFirst('"version":1', '"version":1,"version":1'),
        raw.replaceFirst('"version":1', '"version":1.0'),
        raw.replaceFirst('"number":1', '"number":1,"secret":"x"'),
        raw.replaceFirst('"reserved"', '"stopped"'),
        raw.replaceFirst(
          '"finishedAt":null',
          '"finishedAt":"2026-11-19T00:00:00.000Z"',
        ),
      ]) {
        expect(
          () => SessionProposalRequestJournal.decode(malformed),
          throwsFormatException,
        );
      }
    },
  );
  test('strict metadata refuses false return, mismatched model, paths and timestamps', () {
    final value = requestMetadata();
    for (final patch in <String, Object?>{
      'number': 0,
      'requirementsRevision': -1,
      'workingSha256': 'x' * 64,
      'boardTaskId': '../task',
      'sourceSha256': {'../main.dart': 'd' * 64},
      'startedAt': '2026-11-19T00:00:00',
      'returnedSha256': {'lib/main.dart': 'e' * 64},
    }.entries) {
      final map =
          jsonDecode(jsonEncode(value.toJson())) as Map<String, dynamic>;
      map[patch.key] = patch.value;
      expect(
        () => SessionProposalRequest.fromJson(map),
        throwsFormatException,
        reason: patch.key,
      );
    }
    for (final hashes in [
      <String, String>{},
      {'lib/new.dart': 'e' * 64},
      {'lib/main.dart': 'd' * 64},
    ]) {
      expect(
        () => value.finish(
          SessionProposalRequestStatus.returnedValidated,
          at: value.startedAt,
          returnedSha256: hashes,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => value.finish(
        SessionProposalRequestStatus.returnedValidated,
        at: value.startedAt,
        returnedSha256: {'lib/main.dart': 'e' * 64},
        responseModel: 'other',
      ),
      throwsFormatException,
    );
    expect(
      () => value.finish(
        SessionProposalRequestStatus.failedLocally,
        at: value.startedAt.subtract(const Duration(seconds: 1)),
      ),
      throwsFormatException,
    );
  });
  test('bounded history rejects gaps, duplicate numbering, huge input and overflow', () {
    expect(
      () => SessionProposalRequestJournal([requestMetadata(number: 2)]),
      throwsFormatException,
    );
    expect(
      () =>
          SessionProposalRequestJournal([requestMetadata(), requestMetadata()]),
      throwsFormatException,
    );
    final full = SessionProposalRequestJournal([
      for (var i = 1; i <= 32; i++) requestMetadata(number: i),
    ]);
    expect(
      SessionProposalRequestJournal.decode(full.encode()).requests,
      hasLength(32),
    );
    expect(() => requestMetadata(number: 33), throwsFormatException);
    expect(
      () => SessionProposalRequestJournal.decode(
        ' ' * (SessionProposalRequestJournal.maxEncodedBytes + 1),
      ),
      throwsFormatException,
    );
  });
}
