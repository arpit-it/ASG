// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/session_proposal_reference.dart';
import 'package:asg/models/session_proposal_request.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_request_lineage_test.dart' show lineageFixture;

void main() {
  test(
    'identical returned content retains distinct explicit entry identity',
    () async {
      final f = await lineageFixture();
      final second = SessionProposalRequest.fromJson({
        ...f.request.toJson(),
        'number': 2,
      });
      final a = SessionProposalRequestReference.fromRequest(f.request);
      final b = SessionProposalRequestReference.fromRequest(second);
      expect(a.requestSha256, isNot(b.requestSha256));
      expect(a.matches(second), isFalse);
      expect(a.matches(f.request), isTrue);
      expect(
        SessionProposalRequestReference.decode(a.encode()).encode(),
        a.encode(),
      );
      expect(
        utf8.encode(a.encode()).length,
        lessThanOrEqualTo(SessionProposalRequestReference.maxEncodedBytes),
      );
      for (final status in ['reserved', 'failedLocally', 'cancelledLocally']) {
        final value = SessionProposalRequest.fromJson({
          ...f.request.toJson(),
          'status': status,
          'finishedAt': status == 'reserved'
              ? null
              : f.request.finishedAt!.toIso8601String(),
          'returnedSha256': <String, String>{},
          'modelRequest': const ModelRequestProvenance(
            model: 'supplied-request',
            outputTokens: 4096,
          ).toJson(),
        });
        expect(
          () => SessionProposalRequestReference.fromRequest(value),
          throwsFormatException,
        );
        expect(a.matches(value), isFalse);
      }
    },
  );
  test('reference rejects malformed, ambiguous, foreign-shaped and oversized input', () async {
    final f = await lineageFixture();
    final raw = f.origin.reference.encode();
    for (final bad in [
      ' $raw',
      raw.replaceFirst('"version":1', '"version":1.0'),
      raw.replaceFirst('"number":1', '"number":1,"number":1'),
      raw.replaceFirst('"number":1', '"number":1,"unknown":0'),
      raw.replaceFirst('"number":1', '"number":33'),
      ' ' * (SessionProposalRequestReference.maxEncodedBytes + 1),
    ]) {
      expect(
        () => SessionProposalRequestReference.decode(bad),
        throwsFormatException,
      );
    }
    expect(
      () => SessionProposalRequestReference(
        projectId: '../project',
        sessionId: 'session',
        number: 1,
        requestSha256: 'a' * 64,
      ),
      throwsFormatException,
    );
    expect(
      () => SessionProposalRequestReference(
        projectId: 'project',
        sessionId: 'session',
        number: 1,
        requestSha256: 'A' * 64,
      ),
      throwsFormatException,
    );
  });
  test('origin preserves formatted raw bytes and refuses a typed substitute or changed entry', () async {
    final f = await lineageFixture(formatted: true);
    f.origin.requireRequest(f.request);
    expect(f.origin.requestSessionRecord, contains('\n'));
    final normalized = SessionProposalOrigin(
      reference: f.origin.reference,
      requestSessionRecord: jsonEncode(f.origin.requestSession.toJson()),
    );
    expect(() => normalized.requireRequest(f.request), throwsFormatException);
    final other = SessionProposalRequest.fromJson({
      ...f.request.toJson(),
      'approvalSha256': 'a' * 64,
    });
    expect(() => f.origin.requireRequest(other), throwsFormatException);
    expect(
      () => f.origin.requestSession.dispatches.clear(),
      throwsUnsupportedError,
    );
  });
  test('origin extension rejects cancellation, foreign graph and changed existing prefix', () async {
    final f = await lineageFixture(priorAdmissions: 2);
    f.origin.requireExtension(f.lineage.admissionSession);
    expect(
      () => f.origin.requireExtension(
        f.lineage.admissionSession.requestCancellation(),
      ),
      throwsFormatException,
    );
    final foreign = AgentSession.fromJson({
      ...f.lineage.admissionSession.toJson(),
      'sessionId': 'other',
    });
    expect(() => f.origin.requireExtension(foreign), throwsFormatException);
    final first = f.origin.requestSession.observe(
      AgentSessionDispatch(
        boardTaskId: 'Tanalyze',
        runNumber: 1,
        dispatchId: 'candidate-planning-1:3',
      ),
    );
    final captured = SessionProposalOrigin(
      reference: f.origin.reference,
      requestSessionRecord: jsonEncode(first.toJson()),
    );
    final different = f.origin.requestSession.observe(
      AgentSessionDispatch(
        boardTaskId: 'Ttest',
        runNumber: 1,
        dispatchId: 'candidate-planning-1:3',
      ),
    );
    expect(() => captured.requireExtension(different), throwsFormatException);
  });
  test(
    'origin refuses ambiguous or oversized raw session and withdrawn origin',
    () async {
      final f = await lineageFixture();
      final raw = f.origin.requestSessionRecord;
      for (final bad in [
        '{}',
        raw.replaceFirst('"version":1', '"version":1,"version":1'),
        ' ' * (AgentSession.maxEncodedBytes + 1),
        jsonEncode(f.origin.requestSession.requestCancellation().toJson()),
      ]) {
        expect(
          () => SessionProposalOrigin(
            reference: f.origin.reference,
            requestSessionRecord: bad,
          ),
          throwsFormatException,
        );
      }
    },
  );
}
