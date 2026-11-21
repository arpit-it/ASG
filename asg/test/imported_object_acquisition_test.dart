// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_object_acquisition.dart';
import 'package:asg/models/imported_head_index_observation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_head_index_observation_test.dart'
    show headIndexRequest, headIndexObservationData;

Map<String, Object?> objectAcquisitionData({bool packed = true}) => {
  'profile': ImportedObjectAcquisition.profile,
  'loose_object_count': packed ? 1 : 4,
  'packed_object_count': packed ? 3 : 0,
  'encoded_bytes': packed ? 80 : 0,
  'expanded_bytes': 100,
  'max_delta_depth': packed ? 1 : 0,
  'indexes': [
    if (packed)
      {
        'index_sha256': '1' * 64,
        'index_byte_length': 1184,
        'declared_pack_sha1': '2' * 40,
        'pack_file_bytes': 1024,
        'object_count': 4,
      },
  ],
  'whole_pack_integrity_verified': false,
};

void main() {
  test('bounded provenance is immutable and grants no whole pack or write authority', () {
    final value = ImportedObjectAcquisition.fromMap(objectAcquisitionData());
    expect(value.matchesTotals(count: 4, bytes: 100), true);
    expect(value.matchesTotals(count: 3, bytes: 100), false);
    expect(value.matchesTotals(count: 4, bytes: 99), false);
    expect(value.packedObjectCount, 3);
    expect(value.indexes.single.indexByteLength, 1184);
    expect(
      value.wholePackIntegrityVerified ||
          value.repositoryAuthenticated ||
          value.authorizesCommit ||
          value.authorizesMutation,
      false,
    );
    expect(() => value.indexes.clear(), throwsUnsupportedError);
    expect(
      ImportedObjectAcquisition.fromMap(objectAcquisitionData(packed: false))
          .indexes,
      isEmpty,
    );
  });
  test('profile, shape, count and byte limits fail closed', () {
    final d = objectAcquisitionData();
    for (final bad in <Map<String, Object?>>[
      {...d, 'profile': 'direct-loose-object-files'},
      {...d, 'whole_pack_integrity_verified': true},
      {...d, 'loose_object_count': true},
      {...d, 'loose_object_count': -1},
      {...d, 'packed_object_count': 70},
      {...d, 'packed_object_count': 0},
      {...d, 'encoded_bytes': 0},
      {...d, 'encoded_bytes': 524289},
      {...d, 'expanded_bytes': 262145},
      {...d, 'expanded_bytes': 0},
      {...d, 'max_delta_depth': 33},
      {...d, 'indexes': <Object?>[]},
      {...d, 'extra': false},
      {...objectAcquisitionData(packed: false), 'encoded_bytes': 9},
      {...objectAcquisitionData(packed: false), 'max_delta_depth': 1},
    ]) {
      expect(
        () => ImportedObjectAcquisition.fromMap(bad),
        throwsFormatException,
        reason: '$bad',
      );
    }
  });
  test('index geometry, aggregate, aliases and ordering remain strict', () {
    final d = objectAcquisitionData();
    final index = (d['indexes'] as List).single as Map<String, Object?>;
    for (final changed in [
      {...index, 'declared_pack_sha1': '0' * 40},
      {...index, 'index_sha256': 'G' * 64},
      {...index, 'index_byte_length': 1185},
      {...index, 'object_count': 0},
      {...index, 'object_count': 16385},
      {...index, 'pack_file_bytes': 67108865},
      {...index, 'whole_pack_integrity_verified': true},
    ]) {
      expect(
        () => ImportedObjectAcquisition.fromMap({
          ...d,
          'indexes': [changed],
        }),
        throwsFormatException,
      );
    }
    final other = {...index, 'declared_pack_sha1': '3' * 40};
    expect(
      () => ImportedObjectAcquisition.fromMap({
        ...d,
        'indexes': [index, index],
      }),
      throwsFormatException,
    );
    expect(
      () => ImportedObjectAcquisition.fromMap({
        ...d,
        'indexes': [other, index],
      }),
      throwsFormatException,
    );
    expect(
      ImportedObjectAcquisition.fromMap({
        ...d,
        'indexes': [index, other],
      }).indexes.length,
      2,
    );
    final big = {...index, 'object_count': 10000, 'index_byte_length': 281072};
    expect(
      () => ImportedObjectAcquisition.fromMap({
        ...d,
        'indexes': [
          big,
          {...big, 'declared_pack_sha1': '3' * 40},
        ],
      }),
      throwsFormatException,
    );
  });
  test(
    'mutually impossible packed counts bytes depth and index claims refuse',
    () {
      final d = objectAcquisitionData();
      final index = (d['indexes'] as List).single as Map<String, Object?>;
      for (final bad in [
        {...d, 'encoded_bytes': 26},
        {...d, 'encoded_bytes': 393217},
        {...d, 'max_delta_depth': 3},
        {
          ...d,
          'indexes': [
            {...index, 'object_count': 2, 'index_byte_length': 1128},
          ],
        },
      ]) {
        expect(
          () => ImportedObjectAcquisition.fromMap(bad),
          throwsFormatException,
        );
        final r = headIndexRequest();
        expect(
          () => ImportedHeadIndexObservation.fromJson(
            jsonEncode({
              ...headIndexObservationData(r),
              'object_acquisition': bad,
            }),
            request: r,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test('serialized duplicate members and excessive bytes refuse', () {
    final raw = jsonEncode(objectAcquisitionData());
    expect(
      () => ImportedObjectAcquisition.fromJson(
        '{"profile":"wrong",${raw.substring(1)}',
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedObjectAcquisition.fromJson(' ' * 4097),
      throwsFormatException,
    );
  });
  test('new consent rejects old or mismatched acquisition replies', () {
    final r = headIndexRequest();
    expect(r.objectProfile, ImportedObjectAcquisition.profile);
    final d = headIndexObservationData(r);
    d['object_acquisition'] = objectAcquisitionData();
    expect(
      ImportedHeadIndexObservation.fromJson(
        jsonEncode(d),
        request: r,
      ).objectAcquisition!.packedObjectCount,
      3,
    );
    for (final bad in [
      {...d, 'version': 2}..remove('object_acquisition'),
      {...d, 'acquisition': 'direct-loose-object-files'},
      {...d, 'object_acquisition': null},
      {...d, 'object_count': 5},
      {...d, 'object_bytes': 101},
    ]) {
      expect(
        () =>
            ImportedHeadIndexObservation.fromJson(jsonEncode(bad), request: r),
        throwsFormatException,
      );
    }
    final input = jsonDecode(r.requestJson) as Map<String, dynamic>;
    for (final bad in [
      {...input}..remove('object_profile'),
      {...input, 'object_profile': 'unknown'},
      {...input, 'version': 1},
    ]) {
      expect(
        () => ImportedHeadIndexRequest.restore(jsonEncode(bad)),
        throwsFormatException,
      );
    }
  });
  test('legacy request and direct loose history preserve original scope', () {
    final input =
        jsonDecode(headIndexRequest().requestJson) as Map<String, dynamic>;
    input['version'] = 1;
    input.remove('object_profile');
    final r = ImportedHeadIndexRequest.restore(jsonEncode(input));
    expect(r.supportsPackedObjects, false);
    final d = headIndexObservationData(r);
    final old = ImportedHeadIndexObservation.fromJson(
      jsonEncode(d),
      request: r,
    );
    expect(old.objectAcquisition, isNull);
    expect(
      ImportedHeadIndexObservation.fromJson(
        old.recordJson,
        request: r,
      ).recordJson,
      old.recordJson,
    );
    expect(
      () => ImportedHeadIndexObservation.fromJson(
        jsonEncode({
          ...d,
          'version': 3,
          'object_acquisition': objectAcquisitionData(),
        }),
        request: r,
      ),
      throwsFormatException,
    );
  });
}
