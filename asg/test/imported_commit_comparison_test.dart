// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_comparison.dart';
import 'package:asg/models/imported_commit_source_observation.dart';
import 'package:asg/models/imported_source_proposal_record.dart';
import 'package:asg/models/imported_source_baseline.dart';

import 'imported_source_baseline_test.dart' show baselineSaved;

ImportedCommitReadRequest commitRequest(
  ImportedSourceProposalRecord saved, {
  String? commit,
}) => ImportedCommitReadRequest(
  root: saved.root,
  python: '/trusted/python',
  commit: commit ?? 'a' * 40,
  selectedPaths: saved.context.files.map((f) => f.path).toList(),
);
ImportedCommitSourceObservation commitObserved(
  ImportedSourceProposalRecord saved, {
  String? commit,
  String? changed,
  String? reason,
  String? root,
}) => ImportedCommitSourceObservation.fromJson(
  jsonEncode({
    'version': 1,
    'scope': 'imported-commit-source',
    'status': reason == null ? 'observed' : 'refused',
    'reason': reason,
    'root': root ?? saved.root,
    'commit': commit ?? 'a' * 40,
    'selected_paths': saved.context.files.map((f) => f.path).toList(),
    'tree': reason == null ? 'b' * 40 : null,
    'manifest_sha256': reason == null ? 'c' * 64 : null,
    'manifest_files': reason == null ? saved.context.files.length + 1 : null,
    'source_verified': false,
    'working_tree': 'unknown',
    'conflict': 'unknown',
    'files': reason != null
        ? []
        : [
            for (final file in saved.context.files)
              (() {
                final bytes = changed == file.path
                    ? utf8.encode('changed\n')
                    : file.bytes;
                return {
                  'path': file.path,
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
void main() {
  test('complete historical byte comparison binds commit request and observation without authority', () {
    final saved = baselineSaved(), original = baselineSaved().encode();
    final value = ImportedCommitComparison.compare(
      saved: saved,
      request: commitRequest(saved),
      observation: commitObserved(saved),
      observedAt: DateTime.utc(2026),
    );
    expect(value.status, ImportedSourceBaselineStatus.matched);
    expect(value.sourceVerified, false);
    expect(value.files.length, 2);
    expect(value.changedPaths, isEmpty);
    expect(saved.encode(), original);
    expect(() => value.files.clear(), throwsUnsupportedError);
    final other = ImportedCommitComparison.compare(
      saved: saved,
      request: commitRequest(saved, commit: 'd' * 40),
      observation: commitObserved(saved, commit: 'd' * 40),
      observedAt: DateTime.utc(2026),
    );
    expect(other.digest, isNot(value.digest));
    expect(other.requestDigest, isNot(value.requestDigest));
  });
  test('changed target or peer is reported and refused reads invent no after hashes', () {
    final saved = baselineSaved();
    for (final path in ['lib/main.dart', 'test/peer.dart']) {
      final value = ImportedCommitComparison.compare(
        saved: saved,
        request: commitRequest(saved),
        observation: commitObserved(saved, changed: path),
        observedAt: DateTime.utc(2026),
      );
      expect(value.changedPaths, [path]);
      expect(value.status, ImportedSourceBaselineStatus.changed);
    }
    final value = ImportedCommitComparison.compare(
      saved: saved,
      request: commitRequest(saved),
      observation: commitObserved(saved, reason: 'selected_path_missing'),
      observedAt: DateTime.utc(2026),
    );
    expect(value.status, ImportedSourceBaselineStatus.refused);
    expect(value.reason, 'selected_path_missing');
    expect(
      value.files.every(
        (f) => f.afterHash == null && f.afterByteLength == null,
      ),
      true,
    );
  });
  test('wrong root commit and subset attribution refuses privately', () {
    final saved = baselineSaved();
    for (final observation in [
      commitObserved(saved, root: '/other'),
      commitObserved(saved, commit: 'd' * 40),
    ]) {
      expect(
        () => ImportedCommitComparison.compare(
          saved: saved,
          request: commitRequest(saved),
          observation: observation,
          observedAt: DateTime.utc(2026),
        ),
        throwsFormatException,
      );
    }
    final request = ImportedCommitReadRequest(
      root: saved.root,
      python: '/trusted/python',
      commit: 'a' * 40,
      selectedPaths: ['lib/main.dart'],
    );
    expect(
      () => ImportedCommitComparison.compare(
        saved: saved,
        request: request,
        observation: commitObserved(saved),
        observedAt: DateTime.utc(2026),
      ),
      throwsFormatException,
    );
  });
  test('matching byte results still bind differing tree manifest and mode metadata', () {
    final saved = baselineSaved(), observed = commitObserved(baselineSaved());
    Map<String, dynamic> payload() => {
      'version': 1,
      'scope': 'imported-commit-source',
      'status': 'observed',
      'reason': null,
      'root': saved.root,
      'commit': 'a' * 40,
      'selected_paths': observed.selectedPaths,
      'tree': 'b' * 40,
      'manifest_sha256': 'c' * 64,
      'manifest_files': observed.manifestFiles,
      'source_verified': false,
      'working_tree': 'unknown',
      'conflict': 'unknown',
      'files': [
        for (final file in observed.files)
          {
            'path': file.source.path,
            'mode': file.mode,
            'git_blob': file.gitBlob,
            'sha256': file.source.digest,
            'byte_length': file.source.byteLength,
            'content_base64': base64Encode(file.source.bytes),
          },
      ],
    };
    final original = ImportedCommitComparison.compare(
      saved: saved,
      request: commitRequest(saved),
      observation: observed,
      observedAt: DateTime.utc(2026),
    );
    for (final kind in ['tree', 'manifest', 'mode']) {
      final value = payload();
      if (kind == 'tree') value['tree'] = 'd' * 40;
      if (kind == 'manifest') value['manifest_sha256'] = 'e' * 64;
      if (kind == 'mode') (value['files'] as List).first['mode'] = '100755';
      final changed = ImportedCommitComparison.compare(
        saved: saved,
        request: commitRequest(saved),
        observation: ImportedCommitSourceObservation.fromJson(
          jsonEncode(value),
        ),
        observedAt: DateTime.utc(2026),
      );
      expect(changed.matched, true);
      expect(changed.observationDigest, isNot(original.observationDigest));
      expect(changed.digest, isNot(original.digest));
      expect(changed.sourceVerified, false);
    }
  });
}
