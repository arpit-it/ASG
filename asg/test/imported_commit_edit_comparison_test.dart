// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_copy_record.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_edit_record.dart';
import 'package:asg/models/imported_commit_edit_comparison.dart';

import 'imported_commit_proposal_record_test.dart' show historicalRecord;
import 'imported_commit_edit_request_test.dart' show editBasis;
import 'imported_commit_edit_observation_test.dart'
    show sampleEditRequest, editResult;

void main() {
  final original = editBasis(historicalRecord()).history,
      edit = sampleEditRequest();
  final pending = ImportedCommitEditRecord.empty(edit.root)
      .begin(edit, DateTime.utc(2026));
  final ready = pending.settle(edit, editResult(edit), DateTime.utc(2026));
  ImportedCommitEditComparisonRequest request({
    ImportedCommitCopyRecord? copies,
    ImportedCommitEditRecord? edits,
    String python = '/trusted/current-python',
    String nonce = 'd',
  }) => ImportedCommitEditComparisonRequest.create(
    copyHistory: copies ?? original,
    editHistory: edits ?? ready,
    python: python,
    comparisonId: nonce * 32,
  );
  test('read intent binds both prepared journals without authority or replacement disclosure', () {
    final r = request(), data = jsonDecode(r.requestJson) as Map;
    expect(r.copyHistoryDigest, original.digest);
    expect(r.editHistoryDigest, ready.digest);
    expect(r.originalCopy, original.lastPrepared!.observation!.copyPath);
    expect(r.proposedCopy, ready.lastPrepared!.observation!.copyPath);
    expect(r.expectedOriginalFingerprint, edit.expectedSourceFingerprint);
    expect(
      r.expectedProposedFingerprint,
      ready.lastPrepared!.observation!.fingerprint,
    );
    expect(data['path'], edit.selectedPath);
    expect(data['before_sha256'], edit.beforeHash);
    expect(data['after_sha256'], edit.afterHash);
    expect(r.sourceVerified, false);
    expect(r.authorizesMutation, false);
    expect(r.authorizesExecution, false);
    expect(r.requestJson, isNot(contains(edit.replacement)));
    expect(
      ImportedCommitEditComparisonRequest.restore(r.requestJson).matches(r),
      true,
    );
  });
  test(
    'pending and prepared-but-unconfirmed receipts cannot become success',
    () {
      expect(() => request(edits: pending), throwsFormatException);
      final uncertain = pending.settle(
        edit,
        editResult(edit),
        DateTime.utc(2026),
        unconfirmed: true,
      );
      expect(() => request(edits: uncertain), throwsFormatException);
      expect(
        () => request(edits: uncertain.acknowledge(DateTime.utc(2026))),
        throwsFormatException,
      );
    },
  );
  test('changed original journal cannot borrow historical matching labels', () {
    final p = original.begin(
      ImportedCommitCopyRequest.restore(
        jsonEncode({
          ...jsonDecode(original.lastPrepared!.request.requestJson)
              as Map<String, dynamic>,
          'attempt_id': 'f' * 32,
        }),
      ),
      DateTime.utc(2026),
    );
    expect(() => request(copies: p), throwsFormatException);
    expect(
      () => request(copies: p.acknowledge(DateTime.utc(2026))),
      throwsFormatException,
    );
    expect(
      () => request(copies: ImportedCommitCopyRecord.empty(original.root)),
      throwsFormatException,
    );
  });
  test('different original proposal cannot be relabeled by path or commit', () {
    final other = editBasis(historicalRecord(after: 'a different replacement'))
        .history;
    expect(() => request(copies: other), throwsFormatException);
  });
  test(
    'current runtime and fresh nonce bind identity and reject protected paths',
    () {
      final r = request();
      expect(request(python: '/trusted/another-python').matches(r), false);
      expect(request(nonce: 'e').matches(r), false);
      for (final python in [
        '${edit.root}/python',
        '${r.originalCopy}/python',
        '${r.proposedCopy}/python',
        '/alias/../python',
      ]) {
        expect(() => request(python: python), throwsFormatException);
      }
      expect(() => request(nonce: '0'), throwsFormatException);
    },
  );
  test(
    'restore rejects duplicate unknown type hash bound path and mode confusion',
    () {
      final r = request(),
          data = jsonDecode(r.requestJson) as Map<String, dynamic>;
      for (final change in <Map<String, Object?>>[
        {'extra': true},
        {'version': true},
        {'manifest_files': 2049},
        {'original_copy': r.proposedCopy},
        {'proposed_copy': r.originalCopy},
        {'copy_history_sha256': 'bad'},
        {'comparison_id': '0' * 32},
        {'before_sha256': data['after_sha256']},
        {'path': 'lib/../peer.dart'},
        {'path': 'asg/lib/main.dart'},
        {'mode': '120000'},
        {'after_byte_length': 16385},
        {'before_byte_length': -1},
        {'root': '/Stable.app/project'},
        {'proposed_run': 'outside'},
      ]) {
        expect(
          () => ImportedCommitEditComparisonRequest.restore(
            jsonEncode({...data, ...change}),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => ImportedCommitEditComparisonRequest.restore(
          r.requestJson.replaceFirst('{', '{"version":1,'),
        ),
        throwsFormatException,
      );
      expect(
        () => ImportedCommitEditComparisonRequest.restore(
          ' ' * (ImportedCommitEditComparisonRequest.byteLimit + 1),
        ),
        throwsFormatException,
      );
    },
  );
  Map<String, Object?> observed(
    ImportedCommitEditComparisonRequest r, {
    String status = 'matching',
  }) => {
    'version': 1,
    'scope': 'imported-commit-edit-comparison',
    'request_sha256': r.digest,
    'comparison_id': r.comparisonId,
    'original_copy': r.originalCopy,
    'proposed_copy': r.proposedCopy,
    'expected_original_fingerprint': r.expectedOriginalFingerprint,
    'expected_proposed_fingerprint': r.expectedProposedFingerprint,
    'status': status,
    'original_fingerprint': status == 'refused'
        ? null
        : r.expectedOriginalFingerprint,
    'proposed_fingerprint': status == 'refused'
        ? null
        : status == 'changed'
        ? 'f' * 64
        : r.expectedProposedFingerprint,
    'original_files': status == 'refused' ? null : r.manifestFiles,
    'proposed_files': status == 'refused' ? null : r.manifestFiles,
    'original_bytes': status == 'refused' ? null : 100,
    'proposed_bytes': status == 'refused' ? null : 100,
    'selected_matches': status == 'refused' ? null : true,
    'comparison': status == 'refused'
        ? null
        : {
            'schemaVersion': 1,
            'commit': r.commit,
            'digest': status == 'changed'
                ? 'f' * 64
                : r.expectedProposedFingerprint,
            'counts': {
              'added': 0,
              'modified': 1,
              'removed': 0,
              'executableChanged': 0,
            },
            'changes': [
              {
                'path': r.selectedPath,
                'kind': 'modified',
                'executableChanged': false,
              },
            ],
            'truncated': false,
          },
    'reason': status == 'refused' ? 'unavailable' : null,
    'source_verified': false,
    'mutation_authorized': false,
    'execution_authorized': false,
    'recorded_at': DateTime.utc(2026).toIso8601String(),
  };
  test('observation binds both fingerprints and exact selected comparison', () {
    final r = request();
    for (final status in ['matching', 'changed', 'refused']) {
      final v = ImportedCommitEditComparisonObservation.fromJson(
        jsonEncode(observed(r, status: status)),
        request: r,
      );
      expect(v.status.name, status);
      expect(v.authorizesExecution, false);
      expect(v.authorizesMutation, false);
      expect(v.sourceVerified, false);
      expect(v.recordedAt, DateTime.utc(2026));
      if (status != 'refused') {
        expect(v.comparison!.changes.single.path, r.selectedPath);
      }
    }
  });
  test(
    'observation rejects foreign identity claims and partial refused data',
    () {
      final r = request(), d = observed(request());
      for (final change in <Map<String, Object?>>[
        {'request_sha256': 'f' * 64},
        {'comparison_id': 'e' * 32},
        {'original_copy': r.proposedCopy},
        {'source_verified': true},
        {'execution_authorized': true},
        {'mutation_authorized': true},
        {'extra': true},
        {'selected_matches': false},
        {'original_files': 2049},
        {'proposed_bytes': 24 * 1024 * 1024 + 1},
        {'status': 'changed'},
        {'recorded_at': '2026-01-01'},
      ]) {
        expect(
          () => ImportedCommitEditComparisonObservation.fromJson(
            jsonEncode({...d, ...change}),
            request: r,
          ),
          throwsFormatException,
        );
      }
      final refused = observed(r, status: 'refused');
      expect(
        () => ImportedCommitEditComparisonObservation.fromJson(
          jsonEncode({
            ...refused,
            'original_fingerprint': r.expectedOriginalFingerprint,
          }),
          request: r,
        ),
        throwsFormatException,
      );
      expect(
        () => ImportedCommitEditComparisonObservation.fromJson(
          jsonEncode(d),
          request: request(nonce: 'e'),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'matching observation cannot hide different changes or nested authority',
    () {
      final r = request(), d = observed(request());
      final c = d['comparison'] as Map<String, Object?>;
      for (final change in <Map<String, Object?>>[
        {'digest': 'f' * 64},
        {'commit': 'f' * 40},
        {'extra': true},
        {
          'counts': {
            'added': 0,
            'modified': 0,
            'removed': 0,
            'executableChanged': 0,
          },
          'changes': [],
        },
        {
          'changes': [
            {
              'path': 'test/peer.dart',
              'kind': 'modified',
              'executableChanged': false,
            },
          ],
        },
        {
          'changes': [
            {
              'path': '../outside',
              'kind': 'modified',
              'executableChanged': false,
            },
          ],
        },
      ]) {
        expect(
          () => ImportedCommitEditComparisonObservation.fromJson(
            jsonEncode({
              ...d,
              'comparison': {...c, ...change},
            }),
            request: r,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => ImportedCommitEditComparisonObservation.fromJson(
          jsonEncode(d).replaceFirst('{', '{"version":1,'),
          request: r,
        ),
        throwsFormatException,
      );
      expect(
        () => ImportedCommitEditComparisonObservation.fromJson(
          ' ' * (ImportedCommitEditComparisonObservation.responseLimit + 1),
          request: r,
        ),
        throwsFormatException,
      );
    },
  );
}
