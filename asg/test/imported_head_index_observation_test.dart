// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_head_index_observation.dart';
import 'package:asg/models/imported_workfile_comparison.dart';

import 'imported_workfile_comparison_test.dart'
    show workfileRequest, workfileObservationData;

ImportedHeadIndexRequest headIndexRequest({int count = 1, String id = 'f'}) {
  final r = workfileRequest(count: count);
  final o = ImportedWorkfileObservation.fromJson(
    jsonEncode(workfileObservationData(r)),
    request: r,
  );
  return ImportedHeadIndexRequest.create(
    workfileRequest: r,
    workfileObservation: o,
    readId: id * 32,
  );
}

Map<String, Object?> headIndexObservationData(ImportedHeadIndexRequest r) => {
  'version': 2,
  'scope': 'imported-head-index-observation',
  'request_sha256': r.digest,
  'read_id': r.readId,
  'root': r.root,
  'status': 'observed',
  'reason': null,
  'acquisition': 'direct-loose-object-files',
  'reference_acquisition': <String, Object?>{
    'source': 'head',
    'packed_refs_sha256': null,
    'packed_refs_byte_length': null,
    'packed_refs_entry_count': null,
  },
  'head_form': 'direct_oid',
  'declared_ref': null,
  'head_oid': 'a' * 40,
  'tree_oid': 'c' * 40,
  'index_sha256': r.indexHash,
  'object_count': 4,
  'object_bytes': 100,
  'files': [
    for (final f in r.files)
      <String, Object?>{
        'path': f.path,
        'tree_oid': f.indexOid,
        'tree_mode': f.indexMode,
        'index_matches_tree': true,
        'working_bytes_match_tree': true,
        'working_executable_matches_tree': true,
      },
  ],
  'git_state_verified': false,
  'repository_authenticated': false,
  'working_tree': 'unknown',
  'head_membership': 'unknown',
  'filters': 'unknown',
  'untracked': 'unknown',
  'commit_authorized': false,
  'mutation_authorized': false,
  'recorded_at': DateTime.utc(2026).toIso8601String(),
};
void main() {
  test('request binds exact workfile provenance fingerprints selection and nonce without authority', () {
    final r = headIndexRequest(count: 4);
    expect(ImportedHeadIndexRequest.restore(r.requestJson).matches(r), true);
    expect(headIndexRequest(count: 4, id: 'e').digest, isNot(r.digest));
    expect(r.files.length, 4);
    expect(
      r.authorizesCommit || r.authorizesMutation || r.gitStateVerified,
      false,
    );
    expect(() => r.files.clear(), throwsUnsupportedError);
    final d = jsonDecode(r.requestJson) as Map<String, dynamic>;
    for (final k in [
      'workfile_request_sha256',
      'workfile_observation_sha256',
      'index_sha256',
    ]) {
      expect(
        ImportedHeadIndexRequest.restore(jsonEncode({...d, k: 'a' * 64}))
            .digest,
        isNot(r.digest),
      );
    }
    final files = d['selected_files'] as List;
    final f = files.first as Map<String, dynamic>;
    expect(
      ImportedHeadIndexRequest.restore(
        jsonEncode({
          ...d,
          'selected_files': [
            {...f, 'working_executable': true},
            ...files.skip(1),
          ],
        }),
      ).digest,
      isNot(r.digest),
    );
  });
  test('factory rejects failed or foreign workfile observations', () {
    final r = workfileRequest();
    final o = ImportedWorkfileObservation.fromJson(
      jsonEncode(workfileObservationData(r)),
      request: r,
    );
    expect(
      () => ImportedHeadIndexRequest.create(
        workfileRequest: workfileRequest(id: 'e'),
        workfileObservation: o,
        readId: 'f' * 32,
      ),
      throwsFormatException,
    );
    final f = {
      ...workfileObservationData(r),
      'status': 'refused',
      'reason': 'changed',
      'index_sha256': null,
      'files': <Object>[],
    };
    final refused = ImportedWorkfileObservation.fromJson(
      jsonEncode(f),
      request: r,
    );
    expect(
      () => ImportedHeadIndexRequest.create(
        workfileRequest: r,
        workfileObservation: refused,
        readId: 'f' * 32,
      ),
      throwsFormatException,
    );
  });
  test('request rejects malformed scalar paths duplicate keys unsafe aliases and impossible byte bounds', () {
    final r = headIndexRequest(count: 2);
    final d = jsonDecode(r.requestJson) as Map<String, dynamic>;
    final files = d['selected_files'] as List;
    final f = files.first as Map<String, dynamic>;
    final bad = [
      {...d, 'extra': true},
      {...d, 'version': true},
      {...d, 'scope': 'other'},
      {...d, 'read_id': '0' * 32},
      {...d, 'python': '/project/python'},
      {...d, 'root': '/project/../escape'},
      {...d, 'workfile_request_sha256': 'A' * 64},
      {...d, 'index_byte_length': 32},
      {...d, 'index_byte_length': 262145},
      {...d, 'selected_files': <Object>[]},
      {...d, 'selected_files': files.reversed.toList()},
      {
        ...d,
        'selected_files': [f, f],
      },
      {
        ...d,
        'selected_files': [
          {...f, 'path': 'lib/../escape.dart'},
        ],
      },
      {
        ...d,
        'selected_files': [
          {...f, 'index_oid': '0' * 40},
        ],
      },
      {
        ...d,
        'selected_files': [
          {...f, 'index_mode': '120000'},
        ],
      },
      {
        ...d,
        'selected_files': [
          {...f, 'working_byte_length': -1},
        ],
      },
      {
        ...d,
        'selected_files': [
          {...f, 'working_byte_length': 32769},
        ],
      },
      {
        ...d,
        'selected_files': [
          {...f, 'working_raw_blob': 'A' * 40},
        ],
      },
      {
        ...d,
        'selected_files': [
          {...f, 'working_executable': 1},
        ],
      },
      {
        ...d,
        'selected_files': [
          {...f, 'extra': true},
        ],
      },
    ];
    for (final value in bad) {
      expect(
        () => ImportedHeadIndexRequest.restore(jsonEncode(value)),
        throwsFormatException,
        reason: value.toString(),
      );
    }
    expect(
      () => ImportedHeadIndexRequest.restore(
        '{"version":1,${r.requestJson.substring(1)}',
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedHeadIndexRequest.restore(' ' * 16385),
      throwsFormatException,
    );
    final three = jsonDecode(
      headIndexRequest(count: 3).requestJson,
    ) as Map<String, dynamic>;
    for (final file in three['selected_files'] as List) {
      (file as Map)['working_byte_length'] = 32768;
    }
    expect(
      () => ImportedHeadIndexRequest.restore(jsonEncode(three)),
      throwsFormatException,
    );
  });
  test('declared tree matches byte and mode differences and absent paths remain immutable literal facts', () {
    final r = headIndexRequest(count: 3);
    final d = headIndexObservationData(r);
    final files = d['files'] as List;
    (files[0] as Map<String, Object?>).addAll({
      'tree_oid': 'd' * 40,
      'index_matches_tree': false,
      'working_bytes_match_tree': false,
    });
    (files[1] as Map<String, Object?>).addAll({
      'tree_mode': '100755',
      'index_matches_tree': false,
      'working_executable_matches_tree': false,
    });
    (files[2] as Map<String, Object?>).addAll({
      'tree_oid': null,
      'tree_mode': null,
      'index_matches_tree': false,
      'working_bytes_match_tree': false,
      'working_executable_matches_tree': false,
    });
    final value = ImportedHeadIndexObservation.fromJson(
      jsonEncode(d),
      request: r,
    );
    expect(value.observed, true);
    expect(value.files[0].workingBytesMatchTree, false);
    expect(value.files[0].workingExecutableMatchesTree, true);
    expect(value.files[1].workingBytesMatchTree, true);
    expect(value.files[1].workingExecutableMatchesTree, false);
    expect(value.files[2].treeOid, null);
    expect(
      value.authorizesCommit ||
          value.authorizesMutation ||
          value.gitStateVerified ||
          value.repositoryAuthenticated,
      false,
    );
    expect(value.filters, 'unknown');
    expect(value.untracked, 'unknown');
    expect(value.workingTree, 'unknown');
    expect(value.headMembership, 'unknown');
    expect(() => value.files.clear(), throwsUnsupportedError);
    expect(
      ImportedHeadIndexObservation.fromJson(
        value.recordJson,
        request: r,
      ).recordJson,
      value.recordJson,
    );
    final symbolic = {
      ...headIndexObservationData(r),
      'head_form': 'symbolic',
      'declared_ref': 'refs/heads/main',
      'reference_acquisition': <String, Object?>{
        'source': 'loose_ref',
        'packed_refs_sha256': null,
        'packed_refs_byte_length': null,
        'packed_refs_entry_count': null,
      },
    };
    expect(
      ImportedHeadIndexObservation.fromJson(
        jsonEncode(symbolic),
        request: r,
      ).declaredRef,
      'refs/heads/main',
    );
  });
  test('foreign provenance forged authority invalid refs object bounds and contradictory joins refuse', () {
    final r = headIndexRequest();
    final d = headIndexObservationData(r);
    final f = (d['files'] as List).first as Map<String, Object?>;
    final bad = [
      {...d, 'extra': true},
      {...d, 'version': true},
      {...d, 'request_sha256': 'a' * 64},
      {...d, 'read_id': 'e' * 32},
      {...d, 'root': '/other'},
      {...d, 'index_sha256': 'a' * 64},
      {...d, 'acquisition': 'packed-fallback'},
      {...d, 'head_oid': 'a' * 64},
      {...d, 'tree_oid': '0' * 40},
      {...d, 'head_form': 'symbolic', 'declared_ref': 'refs/heads/../escape'},
      {...d, 'head_form': 'direct_oid', 'declared_ref': 'refs/heads/main'},
      {...d, 'object_count': 1},
      {...d, 'object_count': 71},
      {...d, 'object_bytes': 0},
      {...d, 'object_bytes': 262145},
      {...d, 'git_state_verified': true},
      {...d, 'repository_authenticated': true},
      {...d, 'commit_authorized': true},
      {...d, 'mutation_authorized': true},
      {...d, 'working_tree': 'clean'},
      {...d, 'head_membership': 'verified'},
      {...d, 'filters': 'clean'},
      {...d, 'untracked': 'none'},
      {...d, 'files': <Object>[]},
      {
        ...d,
        'files': [f, f],
      },
      {...d, 'reason': 'bounds'},
      {
        ...d,
        'files': [
          {...f, 'index_matches_tree': false},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'working_bytes_match_tree': false},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'working_executable_matches_tree': false},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'path': 'lib/foreign.dart'},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'tree_oid': null},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'tree_mode': '120000'},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'content_base64': 'private'},
        ],
      },
      {...d, 'recorded_at': '2026-01-01'},
    ];
    for (final value in bad) {
      expect(
        () => ImportedHeadIndexObservation.fromJson(
          jsonEncode(value),
          request: r,
        ),
        throwsFormatException,
        reason: value.toString(),
      );
    }
    expect(
      () => ImportedHeadIndexObservation.fromJson(
        '{"version":1,${jsonEncode(d).substring(1)}',
        request: r,
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedHeadIndexObservation.fromJson('x' * 32769, request: r),
      throwsFormatException,
    );
  });
  test(
    'working bytes and mode can match declared tree while index differs',
    () {
      final baseline = workfileRequest();
      final data = workfileObservationData(baseline);
      final file = (data['files'] as List).first as Map;
      file['raw_blob'] = 'd' * 40;
      file['raw_blob_matches'] = false;
      file['executable'] = true;
      file['executable_matches'] = false;
      final observation = ImportedWorkfileObservation.fromJson(
        jsonEncode(data),
        request: baseline,
      );
      final request = ImportedHeadIndexRequest.create(
        workfileRequest: baseline,
        workfileObservation: observation,
        readId: 'f' * 32,
      );
      final result = headIndexObservationData(request);
      (result['files'] as List).first = <String, Object?>{
        'path': request.files.single.path,
        'tree_oid': 'd' * 40,
        'tree_mode': '100755',
        'index_matches_tree': false,
        'working_bytes_match_tree': true,
        'working_executable_matches_tree': true,
      };
      final value = ImportedHeadIndexObservation.fromJson(
        jsonEncode(result),
        request: request,
      );
      expect(value.files.single.indexMatchesTree, false);
      expect(value.files.single.workingBytesMatchTree, true);
      expect(value.files.single.workingExecutableMatchesTree, true);
      expect(value.authorizesCommit, false);
    },
  );
  test('versioned observation binds packed provenance and loose precedence to HEAD form', () {
    final r = headIndexRequest();
    for (final source in ['packed_ref', 'loose_ref', 'head']) {
      final value = ImportedHeadIndexObservation.fromJson(
        jsonEncode({
          ...headIndexObservationData(r),
          'head_form': source == 'head' ? 'direct_oid' : 'symbolic',
          'declared_ref': source == 'head' ? null : 'refs/heads/main',
          'reference_acquisition': {
            'source': source,
            'packed_refs_sha256': 'e' * 64,
            'packed_refs_byte_length': 100,
            'packed_refs_entry_count': 1,
          },
        }),
        request: r,
      );
      expect(value.referenceAcquisition!.hasPackedRefs, true);
      expect(value.referenceAcquisition!.packedRefsHash, 'e' * 64);
      expect(value.referenceAcquisition!.packedRefsEntryCount, 1);
      expect(value.authorizesCommit, false);
      expect(
        ImportedHeadIndexObservation.fromJson(
          value.recordJson,
          request: r,
        ).recordJson,
        value.recordJson,
      );
    }
  });
  test(
    'legacy missing or contradictory acquisition results cannot be promoted',
    () {
      final r = headIndexRequest();
      final d = headIndexObservationData(r);
      for (final bad in [
        {...d, 'version': 1},
        {...d}..remove('reference_acquisition'),
        {...d, 'reference_acquisition': null},
        {
          ...d,
          'reference_acquisition': {
            'source': 'packed_ref',
            'packed_refs_sha256': null,
            'packed_refs_byte_length': null,
            'packed_refs_entry_count': null,
          },
        },
        {...d, 'head_form': 'symbolic', 'declared_ref': 'refs/heads/main'},
        {
          ...d,
          'reference_acquisition': {
            'source': 'loose_ref',
            'packed_refs_sha256': null,
            'packed_refs_byte_length': null,
            'packed_refs_entry_count': null,
          },
        },
        {
          ...d,
          'reference_acquisition': {
            'source': 'head',
            'packed_refs_sha256': 'e' * 64,
            'packed_refs_byte_length': 100,
            'packed_refs_entry_count': 1,
            'authenticated': true,
          },
        },
      ]) {
        expect(
          () => ImportedHeadIndexObservation.fromJson(
            jsonEncode(bad),
            request: r,
          ),
          throwsFormatException,
        );
      }
      final raw = jsonEncode(d).replaceFirst(
        '"source":"head"',
        '"source":"head","source":"packed_ref"',
      );
      expect(
        () => ImportedHeadIndexObservation.fromJson(raw, request: r),
        throwsFormatException,
      );
    },
  );
  test('failure statuses carry no partial HEAD object index or file joins', () {
    final r = headIndexRequest();
    final d = headIndexObservationData(r);
    for (final reason in [
      'unsupported_layout',
      'missing_loose_object',
      'invalid_object',
      'bounds',
      'changed',
      'index_changed',
      'working_file_changed',
      'invalid_request',
      'unavailable',
      'stopped',
    ]) {
      final f = {
        ...d,
        'status': reason == 'stopped' ? 'stopped' : 'refused',
        'reason': reason,
        'acquisition': null,
        'reference_acquisition': null,
        'head_form': null,
        'declared_ref': null,
        'head_oid': null,
        'tree_oid': null,
        'index_sha256': null,
        'object_count': 0,
        'object_bytes': 0,
        'files': <Object>[],
      };
      expect(
        ImportedHeadIndexObservation.fromJson(
          jsonEncode(f),
          request: r,
        ).observed,
        false,
      );
      for (final k in [
        'acquisition',
        'reference_acquisition',
        'head_form',
        'declared_ref',
        'head_oid',
        'tree_oid',
        'index_sha256',
        'object_count',
        'object_bytes',
        'files',
      ]) {
        final value = d[k] ?? 'unexpected';
        expect(
          () => ImportedHeadIndexObservation.fromJson(
            jsonEncode({...f, k: value}),
            request: r,
          ),
          throwsFormatException,
        );
      }
    }
    final stopped = {
      ...d,
      'status': 'refused',
      'reason': 'stopped',
      'acquisition': null,
      'head_form': null,
      'declared_ref': null,
      'head_oid': null,
      'tree_oid': null,
      'index_sha256': null,
      'object_count': 0,
      'object_bytes': 0,
      'files': <Object>[],
    };
    expect(
      () => ImportedHeadIndexObservation.fromJson(
        jsonEncode(stopped),
        request: r,
      ),
      throwsFormatException,
    );
  });
}
