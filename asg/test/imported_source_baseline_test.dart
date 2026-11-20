// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/imported_source_context.dart';
import 'package:asg/models/imported_source_proposal.dart';
import 'package:asg/models/imported_source_proposal_record.dart';
import 'package:asg/models/project_source_observation.dart';
import 'package:asg/models/imported_source_baseline.dart';

import 'imported_source_proposal_record_test.dart' show historicalRecord;

ImportedSourceProposalRecord baselineSaved() {
  final old = historicalRecord();
  final data = jsonDecode(old.context.recordJson) as Map<String, dynamic>;
  data['selected_paths'] = ['lib/main.dart', 'test/peer.dart'];
  data['files'] = [
    data['files'][0],
    {...data['files'][0] as Map, 'path': 'test/peer.dart'},
  ];
  final context = ImportedSourceContext.restore(jsonEncode(data));
  final plan = ImportedPlan(
    text: old.plan.text,
    context: context.recordJson,
    approved: true,
    recordedAt: old.plan.recordedAt,
  );
  return ImportedSourceProposalRecord.create(
    context: context,
    plan: plan,
    proposal: ImportedSourceProposal.create(
      context: context,
      plan: plan,
      path: 'lib/main.dart',
      replacement: old.proposal.replacement,
    ),
    recordedAt: old.recordedAt,
  );
}

ProjectSourceObservation baselineObserved(
  ImportedSourceProposalRecord saved, {
  String? changed,
}) => ProjectSourceObservation.fromJson(
  jsonEncode({
    'version': 1,
    'scope': 'project-source-files',
    'status': 'observed',
    'reason': null,
    'selected_paths': saved.context.files.map((f) => f.path).toList(),
    'source_verified': false,
    'files': [
      for (final f in saved.context.files)
        {
          'path': f.path,
          'byte_length': utf8
              .encode(f.path == changed ? 'changed\n' : f.text)
              .length,
          'sha256': sha256
              .convert(utf8.encode(f.path == changed ? 'changed\n' : f.text))
              .toString(),
          'content_base64': base64Encode(
            utf8.encode(f.path == changed ? 'changed\n' : f.text),
          ),
        },
    ],
  }),
);
ProjectSourceReadRequest baselineRequest(
  ImportedSourceProposalRecord saved, {
  String? root,
  String python = '/trusted/python',
  List<String>? paths,
}) => ProjectSourceReadRequest(
  root: root ?? saved.root,
  python: python,
  selectedPaths: paths ?? saved.context.files.map((f) => f.path).toList(),
);
void main() {
  test('exact full captured bytes yield bounded immutable unverified observation identity', () {
    final saved = baselineSaved(), fresh = baselineObserved(baselineSaved());
    final value = ImportedSourceBaseline.compare(
      saved: saved,
      request: baselineRequest(saved),
      observation: fresh,
      observedAt: DateTime.utc(2026),
    );
    expect(value.status, ImportedSourceBaselineStatus.matched);
    expect(value.matched, true);
    expect(value.sourceVerified, false);
    expect(value.savedRecordDigest, saved.digest);
    expect(value.files.length, 2);
    expect(value.files.first.matches, true);
    expect(value.files.first.beforeHash, fresh.files.first.digest);
    expect(value.changedPaths, isEmpty);
    expect(() => value.files.clear(), throwsUnsupportedError);
    expect(() => value.changedPaths.clear(), throwsUnsupportedError);
    expect(
      utf8.encode(value.recordJson).length,
      lessThanOrEqualTo(ImportedSourceBaseline.recordByteLimit),
    );
    final later = ImportedSourceBaseline.compare(
      saved: saved,
      request: baselineRequest(saved),
      observation: fresh,
      observedAt: DateTime.utc(2027),
    );
    expect(later.digest, isNot(value.digest));
    expect(later.observationDigest, value.observationDigest);
  });
  test(
    'changed target or peer is reported without altering historical record',
    () {
      final saved = baselineSaved(), original = baselineSaved().encode();
      for (final changed in ['lib/main.dart', 'test/peer.dart']) {
        final value = ImportedSourceBaseline.compare(
          saved: saved,
          request: baselineRequest(saved),
          observation: baselineObserved(saved, changed: changed),
          observedAt: DateTime.utc(2026),
        );
        expect(value.status, ImportedSourceBaselineStatus.changed);
        expect(value.matched, false);
        expect(value.changedPaths, [changed]);
        expect(value.sourceVerified, false);
        expect(saved.encode(), original);
      }
    },
  );
  test('typed missing unsafe and changed refusals never invent fresh source hashes', () {
    final saved = baselineSaved();
    for (final pair in [
      ('invalid', 'source_missing'),
      ('unsupported', 'unsafe_source'),
      ('changed', 'source_changed'),
    ]) {
      final observation = ProjectSourceObservation.fromJson(
        jsonEncode({
          'version': 1,
          'scope': 'project-source-files',
          'status': pair.$1,
          'reason': pair.$2,
          'selected_paths': ['lib/main.dart', 'test/peer.dart'],
          'files': [],
          'source_verified': false,
        }),
      );
      final value = ImportedSourceBaseline.compare(
        saved: saved,
        request: baselineRequest(saved),
        observation: observation,
        observedAt: DateTime.utc(2026),
      );
      expect(value.status, ImportedSourceBaselineStatus.refused);
      expect(value.reason, pair.$2);
      expect(value.matched, false);
      expect(
        value.files.every(
          (f) => f.afterHash == null && f.afterByteLength == null,
        ),
        true,
      );
      expect(value.changedPaths, isEmpty);
    }
  });
  test('wrong root subset order response readset or unsafe interpreter refuses privately', () {
    final saved = baselineSaved(), fresh = baselineObserved(baselineSaved());
    for (final request in [
      baselineRequest(saved, root: '/other'),
      baselineRequest(saved, paths: ['lib/main.dart']),
      baselineRequest(saved, paths: ['test/peer.dart', 'lib/main.dart']),
      baselineRequest(saved, python: '/project/python'),
      baselineRequest(saved, python: 'relative/python'),
      baselineRequest(saved, python: '/trusted/../python'),
      baselineRequest(saved, python: '/trusted/\ud800'),
      baselineRequest(saved, python: '/trusted/${'x' * 4096}'),
    ]) {
      expect(
        () => ImportedSourceBaseline.compare(
          saved: saved,
          request: request,
          observation: fresh,
          observedAt: DateTime.utc(2026),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'private error',
            'Source baseline comparison inputs are invalid or exceed local limits.',
          ),
        ),
      );
    }
    expect(
      () => ImportedSourceBaseline.compare(
        saved: saved,
        request: baselineRequest(saved),
        observation: ProjectSourceObservation.unavailable(),
        observedAt: DateTime.utc(2026),
      ),
      throwsFormatException,
    );
  });
  test(
    'comparison record has no apply execution or current approval field',
    () {
      final saved = baselineSaved();
      final value = ImportedSourceBaseline.compare(
        saved: saved,
        request: baselineRequest(saved),
        observation: baselineObserved(saved),
        observedAt: DateTime.utc(2026),
      );
      final data = jsonDecode(value.recordJson) as Map;
      expect(data.keys.toSet(), {
        'version',
        'scope',
        'source_verified',
        'root',
        'saved_record_sha256',
        'request_sha256',
        'observation_sha256',
        'observed_at',
        'status',
        'reason',
        'files',
      });
      expect(data['source_verified'], false);
      expect(data['scope'], 'imported-source-baseline');
      final requestJson = jsonEncode({
        'root': saved.root,
        'python': '/trusted/python',
        'selected_paths': ['lib/main.dart', 'test/peer.dart'],
      });
      expect(
        value.requestDigest,
        sha256.convert(utf8.encode(requestJson)).toString(),
      );
    },
  );
}
