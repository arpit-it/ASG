// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_index_observation.dart';

ImportedIndexReadRequest indexRequest({
  String root = '/project',
  String python = '/trusted/python',
  String nonce = 'a',
}) => ImportedIndexReadRequest(root: root, python: python, readId: nonce * 32);
Map<String, Object?> indexObservationData(
  ImportedIndexReadRequest r, {
  List<Map<String, Object?>>? entries,
  List<String> caches = const [],
}) {
  final values =
      entries ??
      [
        {'path': 'lib/main.dart', 'mode': '100644', 'oid': 'b' * 40},
      ];
  return {
    'version': 1,
    'scope': 'imported-index-observation',
    'request_sha256': r.digest,
    'read_id': r.readId,
    'root': r.root,
    'status': 'observed',
    'reason': null,
    'format': 'index-v2-sha1',
    'index_sha256': 'c' * 64,
    'index_byte_length':
        32 +
        values.fold<int>(
          0,
          (total, e) =>
              total + ((62 + (e['path'] as String).length + 1 + 7) ~/ 8) * 8,
        ) +
        caches.length * 8,
    'optional_caches': caches,
    'entries': values,
    'git_state_verified': false,
    'working_tree': 'unknown',
    'head_membership': 'unknown',
    'commit_authorized': false,
    'mutation_authorized': false,
    'recorded_at': DateTime.utc(2026).toIso8601String(),
  };
}

void main() {
  test('request binds literal root interpreter nonce and grants no commit authority', () {
    final r = indexRequest();
    expect(ImportedIndexReadRequest.restore(r.requestJson).matches(r), true);
    expect(r.authorizesCommit, false);
    expect(r.authorizesMutation, false);
    expect(indexRequest(nonce: 'b').digest, isNot(r.digest));
    expect(
      indexRequest(python: '/trusted/other-python').digest,
      isNot(r.digest),
    );
    expect(indexRequest(root: '/other').digest, isNot(r.digest));
  });
  test('request refuses malformed fields duplicates bounds aliases and invalid scalar paths', () {
    final raw = jsonDecode(indexRequest().requestJson) as Map<String, dynamic>;
    for (final edit in [
      <String, Object?>{'version': true},
      {'extra': true},
      {'root': '/project/../outside'},
      {'root': 'relative'},
      {'root': '/'},
      {'python': '/PROJECT/python'},
      {'root': '/trusted/python/child'},
      {'read_id': '0' * 32},
      {'read_id': 'a' * 31},
      {'python': '/trusted/${String.fromCharCode(0xd800)}'},
    ]) {
      expect(
        () => ImportedIndexReadRequest.restore(jsonEncode({...raw, ...edit})),
        throwsFormatException,
      );
    }
    expect(
      () => ImportedIndexReadRequest.restore(
        '{"version":1,${indexRequest().requestJson.substring(1)}',
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedIndexReadRequest.restore(' ' * 16385),
      throwsFormatException,
    );
  });
  test('observed empty or regular declarations and known opaque TREE cache stay immutable and nonauthorizing', () {
    final r = indexRequest();
    for (final entries in [
      <Map<String, Object?>>[],
      [
        <String, Object?>{'path': 'a', 'mode': '100644', 'oid': 'b' * 40},
        <String, Object?>{'path': 'b', 'mode': '100755', 'oid': 'd' * 40},
      ],
    ]) {
      final d = indexObservationData(r, entries: entries, caches: ['TREE']);
      final v = ImportedIndexObservation.fromJson(jsonEncode(d), request: r);
      expect(v.observed, true);
      expect(v.entries.length, entries.length);
      expect(v.optionalCaches, ['TREE']);
      expect(v.workingTree, 'unknown');
      expect(v.headMembership, 'unknown');
      expect(v.gitStateVerified, false);
      expect(v.authorizesCommit, false);
      expect(v.authorizesMutation, false);
      expect(() => v.entries.clear(), throwsUnsupportedError);
      expect(() => v.optionalCaches.clear(), throwsUnsupportedError);
      d['optional_caches'] = [];
      expect(v.optionalCaches, ['TREE']);
      expect(
        ImportedIndexObservation.fromJson(v.recordJson, request: r).recordJson,
        v.recordJson,
      );
    }
  });
  test('foreign receipt or forged authority cannot become observed state', () {
    final r = indexRequest(), d = indexObservationData(indexRequest());
    for (final change in [
      <String, Object?>{'request_sha256': 'd' * 64},
      {'read_id': 'b' * 32},
      {'root': '/other'},
      {'git_state_verified': true},
      {'working_tree': 'clean'},
      {'head_membership': 'verified'},
      {'commit_authorized': true},
      {'mutation_authorized': true},
      {'extra': 'private'},
      {'scope': 'git-status'},
    ]) {
      expect(
        () => ImportedIndexObservation.fromJson(
          jsonEncode({...d, ...change}),
          request: r,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ImportedIndexObservation.fromJson(
        jsonEncode(d),
        request: indexRequest(nonce: 'b'),
      ),
      throwsFormatException,
    );
  });
  test('unsafe aliased unsorted and unsupported entries or impossible byte claims refuse', () {
    final r = indexRequest();
    for (final path in [
      '',
      '../outside',
      '.git/config',
      'LIB/.GIT/config',
      'a//b',
      '/absolute',
      'a/',
      'café',
      'line\nname',
      'x' * 1025,
    ]) {
      expect(
        () => ImportedIndexObservation.fromJson(
          jsonEncode(
            indexObservationData(
              r,
              entries: [
                {'path': path, 'mode': '100644', 'oid': 'b' * 40},
              ],
            ),
          ),
          request: r,
        ),
        throwsFormatException,
      );
    }
    for (final entries in [
      [
        {'path': 'a', 'mode': '120000', 'oid': 'b' * 40},
      ],
      [
        {'path': 'a', 'mode': '100644', 'oid': '0' * 40},
      ],
      [
        {'path': 'a', 'mode': '100644', 'oid': 'B' * 40},
      ],
      [
        {'path': 'a', 'mode': '100644', 'oid': 'b' * 40, 'stage': 1},
      ],
      [
        {'path': 'b', 'mode': '100644', 'oid': 'b' * 40},
        {'path': 'a', 'mode': '100644', 'oid': 'b' * 40},
      ],
      [
        {'path': 'A', 'mode': '100644', 'oid': 'b' * 40},
        {'path': 'a', 'mode': '100644', 'oid': 'b' * 40},
      ],
    ]) {
      expect(
        () => ImportedIndexObservation.fromJson(
          jsonEncode(indexObservationData(r, entries: entries)),
          request: r,
        ),
        throwsFormatException,
      );
    }
    final d = indexObservationData(r);
    for (final change in [
      <String, Object?>{'index_byte_length': true},
      {'index_byte_length': 32},
      {'index_byte_length': 262145},
      {
        'optional_caches': ['link'],
      },
      {
        'optional_caches': ['TREE', 'TREE'],
      },
      {'format': 'index-v4'},
      {'index_sha256': 'bad'},
    ]) {
      expect(
        () => ImportedIndexObservation.fromJson(
          jsonEncode({...d, ...change}),
          request: r,
        ),
        throwsFormatException,
      );
    }
  });
  test(
    'failure statuses carry no partial declarations or observed identity',
    () {
      final r = indexRequest(), d = indexObservationData(indexRequest());
      const cases = {
        'unsupported': 'format',
        'invalid': 'checksum',
        'changed': 'metadata_changed',
        'unavailable': 'read_unavailable',
        'stopped': 'stopped',
      };
      for (final c in cases.entries) {
        final failure = {
          ...d,
          'status': c.key,
          'reason': c.value,
          'format': null,
          'index_sha256': null,
          'index_byte_length': null,
          'entries': [],
          'optional_caches': [],
        };
        final v = ImportedIndexObservation.fromJson(
          jsonEncode(failure),
          request: r,
        );
        expect(v.observed, false);
        expect(v.entries, isEmpty);
        expect(v.authorizesCommit, false);
        for (final forged in [
          <String, Object?>{'entries': d['entries']},
          {
            'optional_caches': ['TREE'],
          },
          {'format': 'index-v2-sha1'},
          {'index_sha256': 'c' * 64},
          {'index_byte_length': 112},
          {'reason': 'private arbitrary message'},
        ]) {
          expect(
            () => ImportedIndexObservation.fromJson(
              jsonEncode({...failure, ...forged}),
              request: r,
            ),
            throwsFormatException,
          );
        }
      }
    },
  );
  test(
    'duplicate oversized and noncanonical time evidence is refused privately',
    () {
      final r = indexRequest(),
          raw = jsonEncode(indexObservationData(indexRequest()));
      expect(
        () => ImportedIndexObservation.fromJson(
          '{"version":1,${raw.substring(1)}',
          request: r,
        ),
        throwsFormatException,
      );
      expect(
        () => ImportedIndexObservation.fromJson(' ' * 524289, request: r),
        throwsFormatException,
      );
      final d = indexObservationData(r);
      expect(
        () => ImportedIndexObservation.fromJson(
          jsonEncode({...d, 'recorded_at': '2026-01-01'}),
          request: r,
        ),
        throwsFormatException,
      );
    },
  );
}
