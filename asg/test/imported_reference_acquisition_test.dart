// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_reference_acquisition.dart';

Map<String, Object?> acquisition({String source = 'packed_ref'}) => {
  'source': source,
  'packed_refs_sha256': 'a' * 64,
  'packed_refs_byte_length': 100,
  'packed_refs_entry_count': 1,
};
Map<String, Object?> absent(String source) => {
  'source': source,
  'packed_refs_sha256': null,
  'packed_refs_byte_length': null,
  'packed_refs_entry_count': null,
};

void main() {
  test('HEAD and loose declarations can explicitly have no packed table', () {
    for (final source in ['head', 'loose_ref']) {
      final value = ImportedReferenceAcquisition.fromMap(absent(source));
      expect(value.hasPackedRefs, false);
      expect(value.packedRefsByteLength, isNull);
      expect(value.packedRefsEntryCount, isNull);
      expect(value.authorizesCommit, false);
      expect(value.authorizesMutation, false);
      expect(value.repositoryAuthenticated, false);
      expect(
        value.matchesHeadForm(source == 'head' ? 'direct_oid' : 'symbolic'),
        true,
      );
      expect(
        value.matchesHeadForm(source == 'head' ? 'symbolic' : 'direct_oid'),
        false,
      );
      expect(value.matchesHeadForm(null), false);
    }
  });
  test('packed fingerprint remains visible even when HEAD or loose takes precedence', () {
    for (final source in ['head', 'loose_ref', 'packed_ref']) {
      final value = ImportedReferenceAcquisition.fromMap(
        acquisition(source: source),
      );
      expect(value.hasPackedRefs, true);
      expect(value.packedRefsHash, 'a' * 64);
      expect(value.packedRefsByteLength, 100);
      expect(value.packedRefsEntryCount, 1);
      expect(
        ImportedReferenceAcquisition.fromJson(value.recordJson).toJson(),
        value.toJson(),
      );
    }
  });
  test(
    'empty known table is allowed only when another declaration supplies HEAD',
    () {
      for (final source in ['head', 'loose_ref']) {
        final value = ImportedReferenceAcquisition.fromMap({
          ...acquisition(source: source),
          'packed_refs_byte_length': 46,
          'packed_refs_entry_count': 0,
        });
        expect(value.hasPackedRefs, true);
      }
      expect(
        () => ImportedReferenceAcquisition.fromMap(absent('packed_ref')),
        throwsFormatException,
      );
      expect(
        () => ImportedReferenceAcquisition.fromMap({
          ...acquisition(),
          'packed_refs_byte_length': 46,
          'packed_refs_entry_count': 0,
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'unknown, missing, duplicate or authority fields cannot enter the protocol',
    () {
      for (final value in [
        {...acquisition(), 'source': 'guessed'},
        {...acquisition(), 'source': null},
        {...acquisition(), 'commit_authorized': true},
        {...acquisition(), 'repository_authenticated': true},
        {...acquisition()}..remove('packed_refs_sha256'),
      ]) {
        expect(
          () => ImportedReferenceAcquisition.fromMap(value),
          throwsFormatException,
        );
      }
      final raw = jsonEncode(acquisition());
      expect(
        () => ImportedReferenceAcquisition.fromJson(
          raw.replaceFirst('{', '{"source":"head",'),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'partial packed identities refuse rather than becoming absent or unknown',
    () {
      for (final key in [
        'packed_refs_sha256',
        'packed_refs_byte_length',
        'packed_refs_entry_count',
      ]) {
        expect(
          () => ImportedReferenceAcquisition.fromMap({
            ...acquisition(),
            key: null,
          }),
          throwsFormatException,
        );
        expect(
          () => ImportedReferenceAcquisition.fromMap({
            ...absent('head'),
            key: acquisition()[key],
          }),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'table bounds and impossible record counts refuse exact integer violations',
    () {
      for (final pair in <(Object?, Object?)>[
        (45, 0),
        (47, 0),
        (98, 1),
        (262145, 1),
        (262144, 2049),
        (100, -1),
        (100.0, 1),
        (100, 1.0),
        (true, 1),
        (100, false),
        ('100', 1),
      ]) {
        expect(
          () => ImportedReferenceAcquisition.fromMap({
            ...acquisition(),
            'packed_refs_byte_length': pair.$1,
            'packed_refs_entry_count': pair.$2,
          }),
          throwsFormatException,
        );
      }
      expect(
        ImportedReferenceAcquisition.fromMap({
          ...acquisition(),
          'packed_refs_byte_length': 262144,
          'packed_refs_entry_count': 2048,
        }).packedRefsEntryCount,
        2048,
      );
    },
  );
  test(
    'malformed hash labels reject casing, size, whitespace and nonstrings',
    () {
      for (final hash in [
        'A' * 64,
        'a' * 63,
        'a' * 65,
        '${'a' * 63} ',
        7,
        false,
        [],
      ]) {
        expect(
          () => ImportedReferenceAcquisition.fromMap({
            ...acquisition(),
            'packed_refs_sha256': hash,
          }),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'caller map and serialization edits cannot mutate accepted acquisition',
    () {
      final input = acquisition();
      final value = ImportedReferenceAcquisition.fromMap(input);
      final before = value.recordJson;
      input['source'] = 'head';
      input['packed_refs_sha256'] = 'b' * 64;
      value.toJson()['packed_refs_entry_count'] = 2000;
      expect(value.source, ImportedReferenceSource.packedRef);
      expect(value.recordJson, before);
      expect(value.matchesHeadForm('symbolic'), true);
      expect(value.matchesHeadForm('direct_oid'), false);
    },
  );
  test('nonobjects, malformed and excessive payloads refuse without content acceptance', () {
    for (final raw in [
      'null',
      '[]',
      '1',
      'true',
      '"value"',
      '{',
      ' ' * 1025 + jsonEncode(acquisition()),
    ]) {
      expect(
        () => ImportedReferenceAcquisition.fromJson(raw),
        throwsFormatException,
      );
    }
  });
}
