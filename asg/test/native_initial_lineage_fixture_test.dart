// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sembast/sembast_io.dart';

import 'package:flutter_test/flutter_test.dart';

import '../tools/fixtures/native_initial_lineage.dart';

Map<String, Object> challenge({
  int launch = 1,
  String boundary = 'postcommit',
  bool corrupt = false,
}) => {
  'mode': 'initial-lineage',
  'nonce': 'a' * 32,
  'launch': launch,
  'boundary': boundary,
  'corruptOptional': corrupt,
  'sdk': '/supplied/existing-sdk',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (boundary, corrupt, retry) in [
    ('precommit', false, false),
    ('postcommit', false, true),
    ('postcommit', true, false),
  ]) {
    test(
      'same-process native metadata fixture $boundary corrupt$corrupt retry$retry',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'asg-candidate-crash-vm-',
        );
        final root = await temporary.resolveSymbolicLinks();
        final sdk = await Directory('$root/sdk').create();
        Future<Map<String, dynamic>> stage(int launch) async {
          SharedPreferences.setMockInitialValues({});
          final raw = jsonEncode({
            ...challenge(
              launch: launch,
              boundary: boundary,
              corrupt: corrupt && launch == 2,
            ),
            'sdk': await sdk.resolveSymbolicLinks(),
          });
          final run = runNativeInitialLineageFixture(
            root,
            raw,
            holdAfterReport: () async =>
                throw StateError('Supplied pause release; no app crash.'),
          );
          if (launch == 1 || launch == 3) {
            await expectLater(run, throwsStateError);
          } else {
            await run;
          }
          return jsonDecode(
            await File('$root/launch-$launch.json').readAsString(),
          ) as Map<String, dynamic>;
        }

        try {
          final first = await stage(1);
          final second = await stage(2);
          expect(first['targetRunNumber'], 1);
          expect(first['selectedRequestNumber'], 1);
          expect(first['latestRequestNumber'], 2);
          expect(
            first['selectedReturnedSourceSha256'],
            first['latestReturnedSourceSha256'],
          );
          expect(
            first['selectedRequestSha256'],
            isNot(first['latestRequestSha256']),
          );
          expect(second['recordsBefore'], first['recordsAfter']);
          expect((first['counters'] as Map)['startupReturns'], 0);
          expect(
            first['proofState'],
            boundary == 'precommit' ? 'absent' : 'joined',
          );
          expect(
            second['proofState'],
            boundary == 'precommit'
                ? 'absent'
                : corrupt
                ? 'unavailable'
                : 'joined',
          );
          expect((second['counters'] as Map)['hostCreations'], 0);
          expect(second['requestReference'], first['requestReference']);
          if (retry) {
            final third = await stage(3);
            final fourth = await stage(4);
            expect(third['requestReference'], first['requestReference']);
            expect(
              third['capturedAdmissionSessionSha256'],
              (second['recordsAfter'] as Map)['session'],
            );
            expect((third['counters'] as Map)['recoverySourceInspections'], 2);
            expect(fourth['recordsBefore'], third['recordsAfter']);
            expect(fourth['targetRunNumber'], 2);
            expect(fourth['proofState'], 'joined');
            expect((fourth['counters'] as Map)['startupCalls'], 0);
            // Test-only damage to the older companion must fail a fresh join,
            // even when the newest retained companion is still valid.
            final db = await databaseFactoryIo.openDatabase(
              '$root/initial-lineage.db',
            );
            await StoreRef<String, String>('records')
                .record(
                  'studio.candidateRequestLineage.v1.restart-${'a' * 32}.1',
                )
                .put(db, 'Supplied damage to prior companion.');
            await db.close();
            await expectLater(stage(4), throwsFormatException);
          }
        } finally {
          await temporary.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS,
    );
  }

  for (final (boundary, launch) in [
    ('precommit', 1),
    ('precommit', 2),
    ('postcommit', 1),
    ('postcommit', 2),
    ('postcommit', 3),
    ('postcommit', 4),
  ]) {
    test('fixed $boundary launch$launch derives target without claiming commit', () {
      final input = challenge(launch: launch, boundary: boundary);
      final value = NativeInitialLineageChallenge.decode(jsonEncode(input));
      expect(value.toJson(), input);
      expect(value.targetRunNumber, launch >= 3 ? 2 : 1);
      expect(value.projectId, 'restart-${'a' * 32}');
      expect(value.sessionId, 'session-${'a' * 32}');
      expect(
        value.targetDispatchId,
        'candidate-${value.projectId}-${value.targetRunNumber}:3',
      );
      expect(
        value.targetCompanionKey,
        'studio.candidateRequestLineage.v1.${value.projectId}.${value.targetRunNumber}',
      );
      expect(value.toJson().containsKey('committedTargetRunNumber'), isFalse);
    });
  }
  test('optional corruption is a fixed postcommit read-only control', () {
    final value = NativeInitialLineageChallenge.decode(
      jsonEncode(challenge(launch: 2, corrupt: true)),
    );
    expect(value.corruptOptional, isTrue);
    expect(value.stage, 'read-only');
    for (final input in [
      challenge(corrupt: true),
      challenge(launch: 3, corrupt: true),
      challenge(launch: 4, corrupt: true),
      challenge(launch: 2, boundary: 'precommit', corrupt: true),
    ]) {
      expect(
        () => NativeInitialLineageChallenge.fromJson(input),
        throwsFormatException,
      );
    }
  });
  test(
    'strict types, mode isolation and fixed launch boundaries fail closed',
    () {
      final base = challenge();
      for (final (key, value) in <(String, Object)>[
        ('mode', 'task-decision'),
        ('version', 22),
        ('nonce', 'A' * 32),
        ('nonce', 'a' * 31),
        ('launch', 0),
        ('launch', 5),
        ('launch', 2.0),
        ('launch', true),
        ('boundary', 'latest'),
        ('corruptOptional', 1),
        ('sdk', '../sdk'),
        ('sdk', '/sdk/../other'),
        ('sdk', '/sdk\nprivate-token'),
        ('sdk', 'https://example.invalid/sdk'),
        ('command', 'arbitrary'),
      ]) {
        expect(
          () => NativeInitialLineageChallenge.fromJson({...base, key: value}),
          throwsFormatException,
          reason: key,
        );
      }
      for (final key in base.keys) {
        final missing = {...base}..remove(key);
        expect(
          () => NativeInitialLineageChallenge.fromJson(missing),
          throwsFormatException,
        );
      }
      expect(
        () => NativeInitialLineageChallenge.fromJson(
          challenge(launch: 3, boundary: 'precommit'),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'raw duplicate and UTF8 bounds are rejected without private parse data',
    () {
      final raw = jsonEncode(challenge());
      for (final input in [
        raw.replaceFirst('{', '{"mode":"initial-lineage",'),
        '${' ' * NativeInitialLineageChallenge.maxEncodedBytes}$raw',
        jsonEncode({...challenge(), 'sdk': '/${'é' * 2200}'}),
        '{"private-token":',
      ]) {
        try {
          NativeInitialLineageChallenge.decode(input);
          fail('Expected rejection');
        } on FormatException catch (error) {
          expect(error.source, isNull);
          expect('$error', isNot(contains('private-token')));
        }
      }
    },
  );
}
