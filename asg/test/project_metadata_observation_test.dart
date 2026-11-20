// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/project_metadata_observation.dart';
import 'package:flutter_test/flutter_test.dart';

const manifest =
    'name: controlled_app\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n'
    'dependencies:\n  flutter:\n    sdk: flutter\n';
Map<String, Object?> reply({List<int>? bytes}) => {
  'version': 1,
  'scope': 'project-metadata-files',
  'status': 'observed',
  'reason': null,
  'manifest_base64': base64Encode(bytes ?? utf8.encode(manifest)),
  'included_runners': ['android', 'web'],
  'main_present': true,
  'source_verified': false,
};

void main() {
  test(
    'bounded raw observation projects manifest without source authority',
    () {
      final value = ProjectMetadataObservation.parse(jsonEncode(reply()));
      final inspection = value.toInspection('/selected/folder');
      expect(inspection.packageName, 'controlled_app');
      expect(inspection.root, '/selected/folder');
      expect(value.sourceVerified, isFalse);
      expect(value.mainPresent, isTrue);
      expect(value.includedRunners, ['android', 'web']);
      expect(() => value.manifestBytes!.add(0), throwsUnsupportedError);
      expect(() => value.includedRunners.add('ios'), throwsUnsupportedError);
    },
  );
  test('refusal states never retain partial manifest or runner evidence', () {
    for (final entry in {
      'invalid': 'manifest_missing',
      'unsupported': 'unsafe_metadata',
      'changed': 'metadata_changed',
      'unavailable': 'read_unavailable',
    }.entries) {
      final map = reply()
        ..addAll({
          'status': entry.key,
          'reason': entry.value,
          'manifest_base64': null,
          'main_present': null,
          'included_runners': [],
        });
      final value = ProjectMetadataObservation.parse(jsonEncode(map));
      expect(value.manifestBytes, isNull);
      expect(value.mainPresent, isNull);
      expect(() => value.toInspection('/selected'), throwsFormatException);
      map['manifest_base64'] = '';
      expect(
        () => ProjectMetadataObservation.parse(jsonEncode(map)),
        throwsFormatException,
      );
    }
  });
  test('duplicate plain and escaped members cannot override protocol', () {
    final raw = jsonEncode(reply());
    for (final duplicate in [
      r'"version":1,"version":1',
      r'"version":1,"\u0076ersion":1',
    ]) {
      expect(
        () => ProjectMetadataObservation.parse(
          raw.replaceFirst('"version":1', duplicate),
        ),
        throwsFormatException,
      );
    }
  });
  test('base64 requires canonical encoding and decoded byte limit', () {
    for (final encoded in [
      'AA',
      'AA==\n',
      '_w==',
      '!',
      base64Encode(List.filled(65537, 0)),
    ]) {
      final map = reply()..['manifest_base64'] = encoded;
      expect(
        () => ProjectMetadataObservation.parse(jsonEncode(map)),
        throwsFormatException,
      );
    }
    final bytes = List.filled(65536, 255);
    final value = ProjectMetadataObservation.parse(
      jsonEncode(reply(bytes: bytes)),
    );
    expect(value.manifestBytes, bytes);
    expect(() => value.toInspection('/selected'), throwsFormatException);
  });
  test('runner names must be fixed unique and in declared order', () {
    for (final runners in [
      ['web', 'android'],
      ['web', 'web'],
      ['../private'],
      [1],
    ]) {
      final map = reply()..['included_runners'] = runners;
      expect(
        () => ProjectMetadataObservation.parse(jsonEncode(map)),
        throwsFormatException,
      );
    }
  });
  test('extra wrong type and verified assertions are rejected privately', () {
    for (final fields in [
      {'extra': 'private-sentinel'},
      {'version': 1.0},
      {'source_verified': true},
      {'main_present': false},
      {'reason': 'private-sentinel'},
      {'scope': 'other'},
      {'status': 'other'},
      {'included_runners': null},
    ]) {
      final map = reply()..addAll(fields);
      expect(
        () => ProjectMetadataObservation.parse(jsonEncode(map)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString(),
            'private',
            isNot(contains('private-sentinel')),
          ),
        ),
      );
    }
  });
  test('invalid UTF8 YAML and duplicate manifest keys remain private', () {
    for (final bytes in [
      [255],
      utf8.encode('private-sentinel: ['),
      utf8.encode('${manifest}name: private-sentinel\n'),
    ]) {
      final value = ProjectMetadataObservation.parse(
        jsonEncode(reply(bytes: bytes)),
      );
      expect(
        () => value.toInspection('/private-sentinel'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.toString(),
            'private',
            isNot(contains('private-sentinel')),
          ),
        ),
      );
    }
  });
  test(
    'manifest projection retains Flutter name dependency and SDK validation',
    () {
      for (final text in [
        '',
        'name: bad-name',
        'name: valid\nenvironment: {}',
        'name: valid\nenvironment:\n  sdk: ">=3.0.0"\ndependencies: {}',
      ]) {
        final value = ProjectMetadataObservation.parse(
          jsonEncode(reply(bytes: utf8.encode(text))),
        );
        expect(() => value.toInspection('/selected'), throwsFormatException);
      }
    },
  );
  test('raw response bound is enforced without echoing content', () {
    expect(
      () => ProjectMetadataObservation.parse(' ' * 131073),
      throwsFormatException,
    );
  });
}
