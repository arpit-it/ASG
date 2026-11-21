// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_index_observation.dart';
import 'package:asg/models/imported_workfile_comparison.dart';

import 'imported_index_observation_test.dart'
    show indexRequest, indexObservationData;

ImportedWorkfileRequest workfileRequest({int count = 1, String id = 'd'}) {
  final r = indexRequest();
  final paths = List.generate(count, (i) => 'lib/file$i.dart');
  final value = ImportedIndexObservation.fromJson(
    jsonEncode(
      indexObservationData(
        r,
        entries: [
          for (final p in paths) {'path': p, 'mode': '100644', 'oid': 'b' * 40},
        ],
      ),
    ),
    request: r,
  );
  return ImportedWorkfileRequest.create(
    indexRequest: r,
    indexObservation: value,
    paths: paths.reversed.toList(),
    comparisonId: id * 32,
  );
}

Map<String, Object?> workfileObservationData(ImportedWorkfileRequest r) => {
  'version': 1,
  'scope': 'imported-workfile-comparison',
  'request_sha256': r.digest,
  'comparison_id': r.comparisonId,
  'root': r.root,
  'index_sha256': r.indexHash,
  'status': 'observed',
  'reason': null,
  'files': [
    for (final f in r.files)
      {
        'path': f.path,
        'byte_length': 5,
        'sha256': 'e' * 64,
        'raw_blob': f.oid,
        'executable': false,
        'raw_blob_matches': true,
        'executable_matches': true,
      },
  ],
  'git_state_verified': false,
  'head_membership': 'unknown',
  'filters': 'unknown',
  'working_tree': 'unknown',
  'commit_authorized': false,
  'mutation_authorized': false,
  'recorded_at': DateTime.utc(2026).toIso8601String(),
};
void main() {
  test('index provenance sorted selection and nonce remain immutable and nonauthorizing', () {
    final r = workfileRequest(count: 4);
    expect(r.files.map((f) => f.path), [
      'lib/file0.dart',
      'lib/file1.dart',
      'lib/file2.dart',
      'lib/file3.dart',
    ]);
    expect(ImportedWorkfileRequest.restore(r.requestJson).matches(r), true);
    expect(workfileRequest(count: 4, id: 'e').digest, isNot(r.digest));
    expect(
      r.authorizesCommit || r.authorizesMutation || r.gitStateVerified,
      false,
    );
    expect(() => r.files.clear(), throwsUnsupportedError);
    final d = jsonDecode(r.requestJson) as Map<String, dynamic>;
    for (final k in [
      'index_request_sha256',
      'index_observation_sha256',
      'index_sha256',
    ]) {
      expect(
        ImportedWorkfileRequest.restore(jsonEncode({...d, k: 'a' * 64})).digest,
        isNot(r.digest),
      );
    }
  });
  test('creation rejects foreign failed or unindexed selection', () {
    final r = indexRequest();
    final value = ImportedIndexObservation.fromJson(
      jsonEncode(indexObservationData(r)),
      request: r,
    );
    for (final paths in [
      <String>[],
      ['lib/absent.dart'],
      ['../escape.dart'],
      ['lib/main.dart', 'lib/Main.dart'],
    ]) {
      expect(
        () => ImportedWorkfileRequest.create(
          indexRequest: r,
          indexObservation: value,
          paths: paths,
          comparisonId: 'd' * 32,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ImportedWorkfileRequest.create(
        indexRequest: indexRequest(nonce: 'b'),
        indexObservation: value,
        paths: ['lib/main.dart'],
        comparisonId: 'd' * 32,
      ),
      throwsFormatException,
    );
    final failed = {
      ...indexObservationData(r),
      'status': 'invalid',
      'reason': 'missing_index',
      'format': null,
      'index_sha256': null,
      'index_byte_length': null,
      'entries': <Object>[],
      'optional_caches': <Object>[],
    };
    final refusal = ImportedIndexObservation.fromJson(
      jsonEncode(failed),
      request: r,
    );
    expect(
      () => ImportedWorkfileRequest.create(
        indexRequest: r,
        indexObservation: refusal,
        paths: ['lib/main.dart'],
        comparisonId: 'd' * 32,
      ),
      throwsFormatException,
    );
  });
  test(
    'requests reject duplicate unknown unsafe unsorted and impossible fields',
    () {
      final r = workfileRequest(count: 2);
      final d = jsonDecode(r.requestJson) as Map<String, dynamic>;
      final files = d['selected_files'] as List;
      final first = files.first as Map<String, dynamic>;
      final invalid = [
        {...d, 'extra': true},
        {...d, 'version': true},
        {...d, 'scope': 'other'},
        {...d, 'comparison_id': '0' * 32},
        {...d, 'python': '/project/python'},
        {...d, 'root': '/project/../outside'},
        {...d, 'index_sha256': 'A' * 64},
        {...d, 'index_byte_length': 32},
        {...d, 'index_byte_length': 262145},
        {...d, 'selected_files': files.reversed.toList()},
        {
          ...d,
          'selected_files': [first, first],
        },
        {
          ...d,
          'selected_files': [
            {...first, 'oid': '0' * 40},
          ],
        },
        {
          ...d,
          'selected_files': [
            {...first, 'mode': '120000'},
          ],
        },
        {
          ...d,
          'selected_files': [
            {...first, 'path': 'lib/../escape.dart'},
          ],
        },
        {
          ...d,
          'selected_files': [
            {...first, 'path': 'lib/a\\b.dart'},
          ],
        },
        {
          ...d,
          'selected_files': [
            {...first, 'extra': true},
          ],
        },
      ];
      for (final value in invalid) {
        expect(
          () => ImportedWorkfileRequest.restore(jsonEncode(value)),
          throwsFormatException,
          reason: value.toString(),
        );
      }
      expect(
        () => ImportedWorkfileRequest.restore(
          '{"version":1,${r.requestJson.substring(1)}',
        ),
        throwsFormatException,
      );
      expect(
        () => ImportedWorkfileRequest.restore(' ' * 16385),
        throwsFormatException,
      );
    },
  );
  test('raw bytes and executable mode mismatches are independent immutable observations', () {
    final r = workfileRequest(count: 2);
    final d = workfileObservationData(r);
    final files = d['files'] as List;
    (files[0] as Map)['raw_blob'] = 'a' * 40;
    (files[0] as Map)['raw_blob_matches'] = false;
    (files[1] as Map)['executable'] = true;
    (files[1] as Map)['executable_matches'] = false;
    final v = ImportedWorkfileObservation.fromJson(jsonEncode(d), request: r);
    expect(v.observed, true);
    expect(v.files.first.rawBlobMatches, false);
    expect(v.files.first.executableMatches, true);
    expect(v.files.last.rawBlobMatches, true);
    expect(v.files.last.executableMatches, false);
    expect(v.filters, 'unknown');
    expect(v.workingTree, 'unknown');
    expect(v.headMembership, 'unknown');
    expect(
      v.authorizesCommit || v.authorizesMutation || v.gitStateVerified,
      false,
    );
    expect(() => v.files.clear(), throwsUnsupportedError);
    expect(
      ImportedWorkfileObservation.fromJson(v.recordJson, request: r).recordJson,
      v.recordJson,
    );
  });
  test('forged identity authority partial results and contradictory booleans refuse', () {
    final r = workfileRequest();
    final d = workfileObservationData(r);
    final f = (d['files'] as List).single as Map<String, Object>;
    final invalid = [
      {...d, 'extra': true},
      {...d, 'version': true},
      {...d, 'request_sha256': 'a' * 64},
      {...d, 'comparison_id': 'e' * 32},
      {...d, 'root': '/other'},
      {...d, 'index_sha256': 'a' * 64},
      {...d, 'commit_authorized': true},
      {...d, 'mutation_authorized': true},
      {...d, 'git_state_verified': true},
      {...d, 'filters': 'clean'},
      {...d, 'head_membership': 'verified'},
      {...d, 'working_tree': 'clean'},
      {...d, 'files': <Object>[]},
      {
        ...d,
        'files': [f, f],
      },
      {...d, 'reason': 'bounds'},
      {
        ...d,
        'files': [
          {...f, 'raw_blob_matches': false},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'executable_matches': false},
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
          {...f, 'byte_length': -1},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'byte_length': 32769},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'content_base64': 'private'},
        ],
      },
      {
        ...d,
        'files': [
          {...f, 'sha256': 'E' * 64},
        ],
      },
      {...d, 'recorded_at': '2026-01-01'},
    ];
    for (final value in invalid) {
      expect(
        () =>
            ImportedWorkfileObservation.fromJson(jsonEncode(value), request: r),
        throwsFormatException,
        reason: value.toString(),
      );
    }
    expect(
      () => ImportedWorkfileObservation.fromJson(
        '{"version":1,${jsonEncode(d).substring(1)}',
        request: r,
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedWorkfileObservation.fromJson('x' * 32769, request: r),
      throwsFormatException,
    );
  });
  test('aggregate bound applies even when each individual file fits', () {
    for (final count in [2, 3]) {
      final r = workfileRequest(count: count);
      final d = workfileObservationData(r);
      for (final file in d['files'] as List) {
        (file as Map)['byte_length'] = 32768;
      }
      if (count == 2) {
        expect(
          ImportedWorkfileObservation.fromJson(
            jsonEncode(d),
            request: r,
          ).files.length,
          2,
        );
      } else {
        expect(
          () => ImportedWorkfileObservation.fromJson(jsonEncode(d), request: r),
          throwsFormatException,
        );
      }
    }
  });
  test(
    'refusals and Stop carry no partial files or accepted index identity',
    () {
      final r = workfileRequest();
      final d = workfileObservationData(r);
      for (final reason in [
        'unsupported_index',
        'index_changed',
        'unindexed',
        'source_missing',
        'unsafe_source',
        'changed',
        'bounds',
        'unavailable',
        'invalid_request',
        'stopped',
      ]) {
        final f = {
          ...d,
          'status': reason == 'stopped' ? 'stopped' : 'refused',
          'reason': reason,
          'files': <Object>[],
          'index_sha256': null,
        };
        expect(
          ImportedWorkfileObservation.fromJson(
            jsonEncode(f),
            request: r,
          ).observed,
          false,
        );
        expect(
          () => ImportedWorkfileObservation.fromJson(
            jsonEncode({...f, 'files': d['files']}),
            request: r,
          ),
          throwsFormatException,
        );
        expect(
          () => ImportedWorkfileObservation.fromJson(
            jsonEncode({...f, 'index_sha256': r.indexHash}),
            request: r,
          ),
          throwsFormatException,
        );
      }
      expect(
        () => ImportedWorkfileObservation.fromJson(
          jsonEncode({
            ...d,
            'status': 'refused',
            'reason': 'stopped',
            'files': <Object>[],
            'index_sha256': null,
          }),
          request: r,
        ),
        throwsFormatException,
      );
    },
  );
}
