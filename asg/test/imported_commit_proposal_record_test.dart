// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/imported_commit_context.dart';
import 'package:asg/models/imported_commit_proposal.dart';
import 'package:asg/models/imported_commit_proposal_record.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:asg/models/imported_commit_source_observation.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:crypto/crypto.dart';

ImportedCommitContext capturedCommitPlan({
  String text = 'Synthetic source',
  Map<String, String>? texts,
}) {
  final selected = texts ?? {'lib/main.dart': text};
  final request = ImportedCommitReadRequest(
    root: '/project',
    python: '/trusted/python',
    commit: 'a' * 40,
    selectedPaths: selected.keys.toList(),
  );
  final observation = ImportedCommitSourceObservation.fromJson(
    jsonEncode({
      'version': 1,
      'scope': 'imported-commit-source',
      'status': 'observed',
      'reason': null,
      'root': request.root,
      'commit': request.commit,
      'selected_paths': request.selectedPaths,
      'tree': 'b' * 40,
      'manifest_sha256': 'c' * 64,
      'manifest_files': selected.length,
      'source_verified': false,
      'working_tree': 'unknown',
      'conflict': 'unknown',
      'files': [
        for (final e in selected.entries)
          (() {
            final bytes = utf8.encode(e.value);
            return {
              'path': e.key,
              'mode': '100644',
              'git_blob': sha1.convert([
                ...utf8.encode('blob ${bytes.length}\u0000'),
                ...bytes,
              ]).toString(),
              'byte_length': bytes.length,
              'sha256': sha256.convert(bytes).toString(),
              'content_base64': base64Encode(bytes),
            };
          })(),
      ],
    }),
  );
  return ImportedCommitContext.capture(
    inspection: ProjectInspection(
      root: '/project',
      packageName: 'example',
      dartSdk: '^3.0.0',
      runners: ['web'],
    ),
    requirements: RequirementsBoard(),
    request: request,
    observation: observation,
  );
}

ImportedCommitProposalRecord historicalRecord({
  String before = '\ufeffbefore\r\n',
  String after = '\ufeffafter\r\n',
  String planText = 'Reviewed historical change',
}) {
  final context = capturedCommitPlan(text: before);
  final plan = ImportedPlan(
    text: planText,
    context: context.recordJson,
    approved: true,
    recordedAt: DateTime.utc(2026, 11, 20),
  );
  final proposal = ImportedCommitProposal.create(
    context: context,
    plan: plan,
    path: 'lib/main.dart',
    replacement: after,
  );
  return ImportedCommitProposalRecord.create(
    context: context,
    plan: plan,
    proposal: proposal,
    recordedAt: DateTime.utc(2026, 11, 20, 17),
  );
}

void main() {
  test('historical record restores exact original BOM CRLF plan and diff identities', () {
    final saved = historicalRecord();
    final reopened = ImportedCommitProposalRecord.decode(saved.encode());
    expect(reopened.root, '/project');
    expect(reopened.context.recordJson, saved.context.recordJson);
    expect(reopened.plan.toJson(), saved.plan.toJson());
    expect(reopened.proposal.matches(saved.proposal), true);
    expect(reopened.proposal.source.source.text, '\ufeffbefore\r\n');
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
    final data = jsonDecode(
      capturedCommitPlan(
        texts: {'lib/main.dart': 'First', 'test/other.dart': 'Second'},
      ).recordJson,
    ) as Map<String, dynamic>;
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
    final context = ImportedCommitContext.restore(raw);
    final plan = ImportedPlan(
      text: 'Reviewed',
      context: raw,
      approved: true,
      recordedAt: DateTime.utc(2026),
    );
    final proposal = ImportedCommitProposal.create(
      context: context,
      plan: plan,
      path: 'test/other.dart',
      replacement: 'Changed selected second file',
    );
    final value = ImportedCommitProposalRecord.create(
      context: context,
      plan: plan,
      proposal: proposal,
      recordedAt: DateTime.utc(2026),
    );
    final restored = ImportedCommitProposalRecord.decode(value.encode());
    expect(restored.context.files.map((f) => f.source.path), [
      'lib/main.dart',
      'test/other.dart',
    ]);
    expect(restored.context.recordJson, raw);
    expect(restored.proposal.source.source.path, 'test/other.dart');
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
      'x' * (ImportedCommitProposalRecord.byteLimit + 1),
    ]) {
      expect(
        () => ImportedCommitProposalRecord.decode(value),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'private error',
            'Saved committed-source proposal is invalid.',
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
        () => ImportedCommitProposalRecord.decode(jsonEncode(data)),
        throwsFormatException,
      );
    }
  });
  test('historical context restore rejects unknown keys order changes invalid scalar text and deep input', () {
    final raw = capturedCommitPlan().recordJson;
    expect(ImportedCommitContext.restore(raw).recordJson, raw);
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
        () => ImportedCommitContext.restore(jsonEncode(data)),
        throwsFormatException,
      );
    }
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final reordered = <String, dynamic>{
      for (final key in data.keys.toList().reversed) key: data[key],
    };
    expect(
      () => ImportedCommitContext.restore(jsonEncode(reordered)),
      throwsFormatException,
    );
  });
}
