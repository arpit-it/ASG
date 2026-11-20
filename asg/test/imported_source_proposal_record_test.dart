// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/imported_source_context.dart';
import 'package:asg/models/imported_source_proposal.dart';
import 'package:asg/models/imported_source_proposal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_plan_test.dart' show capturedSourcePlan;

ImportedSourceProposalRecord historicalRecord({
  String before = '\ufeffbefore\r\n',
  String after = '\ufeffafter\r\n',
  String planText = 'Reviewed historical change',
}) {
  final context = capturedSourcePlan(text: before);
  final plan = ImportedPlan(
    text: planText,
    context: context.recordJson,
    approved: true,
    recordedAt: DateTime.utc(2026, 11, 20),
  );
  final proposal = ImportedSourceProposal.create(
    context: context,
    plan: plan,
    path: 'lib/main.dart',
    replacement: after,
  );
  return ImportedSourceProposalRecord.create(
    context: context,
    plan: plan,
    proposal: proposal,
    recordedAt: DateTime.utc(2026, 11, 20, 17),
  );
}

void main() {
  test('historical record restores exact original BOM CRLF plan and diff identities', () {
    final saved = historicalRecord();
    final reopened = ImportedSourceProposalRecord.decode(saved.encode());
    expect(reopened.root, '/project');
    expect(reopened.context.recordJson, saved.context.recordJson);
    expect(reopened.plan.toJson(), saved.plan.toJson());
    expect(reopened.proposal.matches(saved.proposal), true);
    expect(reopened.proposal.source.text, '\ufeffbefore\r\n');
    expect(reopened.proposal.replacement, '\ufeffafter\r\n');
    expect(reopened.sourceVerified, false);
    expect(reopened.recordJson, saved.recordJson);
    expect(reopened.digest, saved.digest);
    expect(() => reopened.context.files.clear(), throwsUnsupportedError);
    expect(() => reopened.proposal.diff.lines.clear(), throwsUnsupportedError);
    expect(
      historicalRecord(planText: 'Later reviewed text').proposal.planDigest,
      isNot(saved.proposal.planDigest),
    );
  });
  test('nonempty saved board and selected-file order survive exact history restore', () {
    final data =
        jsonDecode(capturedSourcePlan().recordJson) as Map<String, dynamic>;
    data['requirements'] = RequirementsBoard(
      revision: 3,
      requirements: [
        ProjectRequirement(
          id: 'R1',
          title: 'Literal title',
          acceptance: 'Keep exact data',
        ),
      ],
    ).toJson();
    data['selected_paths'] = ['lib/main.dart', 'test/other.dart'];
    data['files'] = [
      data['files'][0],
      {...data['files'][0] as Map, 'path': 'test/other.dart'},
    ];
    final raw = jsonEncode(data);
    final context = ImportedSourceContext.restore(raw);
    final plan = ImportedPlan(
      text: 'Reviewed',
      context: raw,
      approved: true,
      recordedAt: DateTime.utc(2026),
    );
    final proposal = ImportedSourceProposal.create(
      context: context,
      plan: plan,
      path: 'test/other.dart',
      replacement: 'Changed selected second file',
    );
    final value = ImportedSourceProposalRecord.create(
      context: context,
      plan: plan,
      proposal: proposal,
      recordedAt: DateTime.utc(2026),
    );
    final restored = ImportedSourceProposalRecord.decode(value.encode());
    expect(restored.context.files.map((f) => f.path), [
      'lib/main.dart',
      'test/other.dart',
    ]);
    expect(restored.context.recordJson, raw);
    expect(restored.proposal.source.path, 'test/other.dart');
    expect(restored.proposal.matches(proposal), true);
    expect(
      jsonDecode(restored.context.recordJson)['requirements']['revision'],
      3,
    );
  });
  test('unpaired reviewed-plan scalar is refused without replacement-byte normalization', () {
    expect(() => historicalRecord(planText: '\ud800'), throwsFormatException);
  });
  test('malformed duplicate unknown noncanonical or oversized envelope refuses privately', () {
    final saved = historicalRecord();
    final raw = saved.encode();
    for (final value in [
      'private malformed',
      '{}',
      '$raw ',
      raw.replaceFirst('{', '{"version":1,'),
      raw.replaceFirst('{', r'{"\u0076ersion":1,'),
      raw.replaceFirst('{', '{"private_unknown":true,'),
      'x' * (ImportedSourceProposalRecord.byteLimit + 1),
    ]) {
      expect(
        () => ImportedSourceProposalRecord.decode(value),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'private error',
            'Saved source proposal is invalid.',
          ),
        ),
      );
    }
  });
  test('root plan source and replacement tampering cannot preserve historical identity', () {
    final original = historicalRecord().encode();
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (data) => data['root'] = '/other',
      (data) => data['version'] = 1.0,
      (data) => data['plan']['approved'] = false,
      (data) => data['plan']['text'] = 'Substituted later plan',
      (data) => data['plan']['unknown'] = 'private',
      (data) {
        final c = jsonDecode(data['plan']['context'] as String) as Map;
        c['files'][0]['text'] = 'Substituted original source';
        data['plan']['context'] = jsonEncode(c);
      },
      (data) {
        final p = jsonDecode(data['proposal'] as String) as Map;
        p['replacement'] = 'Substituted replacement';
        data['proposal'] = jsonEncode(p);
      },
      (data) => data['proposal'] = (data['proposal'] as String).replaceFirst(
        '{',
        '{"version":1,',
      ),
      (data) => data['recordedAt'] = 'not a time',
    ]) {
      final data = jsonDecode(original) as Map<String, dynamic>;
      mutate(data);
      expect(
        () => ImportedSourceProposalRecord.decode(jsonEncode(data)),
        throwsFormatException,
      );
    }
  });
  test('historical context restore rejects unknown keys order changes invalid scalar text and deep input', () {
    final raw = capturedSourcePlan().recordJson;
    expect(ImportedSourceContext.restore(raw).recordJson, raw);
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (data) => data['unknown'] = true,
      (data) => data['source_verified'] = true,
      (data) => data['files'][0]['text'] = '\ud800',
      (data) => data['metadata']['package'] = '\ud800',
      (data) => data['requirements']['unknown'] = true,
      (data) => data['requirements']['tasks'] = [
        for (var i = 0; i < 1; i++) List.generate(1, (_) => 'invalid'),
      ],
      (data) {
        Object value = 'deep';
        for (var i = 0; i < 40; i++) {
          value = [value];
        }
        data['metadata']['extra'] = value;
      },
    ]) {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      mutate(data);
      expect(
        () => ImportedSourceContext.restore(jsonEncode(data)),
        throwsFormatException,
      );
    }
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final reordered = <String, dynamic>{
      for (final key in data.keys.toList().reversed) key: data[key],
    };
    expect(
      () => ImportedSourceContext.restore(jsonEncode(reordered)),
      throwsFormatException,
    );
  });
}
