// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/models/session_proposal_request.dart';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/candidate_request_lineage.dart';
import 'package:asg/models/candidate_repair_lineage.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:asg/services/agent_task_history_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tools/fixtures/native_initial_unresolved.dart';

Map<String, Object> _challenge(int launch) => {
  'mode': 'initial-unresolved',
  'nonce': 'a' * 32,
  'launch': launch,
  'sdk': '/supplied/existing-sdk',
  'explicitNext': launch >= 3,
};

Future<Directory> _privateRoot(String prefix) async {
  final temporary = await Directory.systemTemp.createTemp(prefix);
  try {
    final root = await temporary.resolveSymbolicLinks();
    final mode = await Process.run('/bin/chmod', ['0700', root]);
    expect(mode.exitCode, 0);
    expect(
      (await Directory(root).stat()).mode & 0x3f,
      0,
      reason: 'The VM fixture must meet the same private-root contract.',
    );
    return temporary;
  } catch (_) {
    await temporary.delete(recursive: true);
    rethrow;
  }
}

Future<Map<String, String>> _physical(String root) async {
  final db = await databaseFactoryIo.openDatabase(
    '$root/initial-unresolved.db',
  );
  try {
    return {
      for (final row in await StoreRef<String, String>('records').find(db))
        row.key: row.value,
    };
  } finally {
    await db.close();
  }
}

Future<Map<String, dynamic>> _stage(
  String root,
  int launch, {
  String? nonce,
}) async {
  SharedPreferences.setMockInitialValues({});
  final value = {..._challenge(launch), 'sdk': '$root/sdk', 'nonce': ?nonce};
  final pending = runNativeInitialUnresolvedFixture(
    root,
    jsonEncode(value),
    holdAfterReport: () async {
      throw StateError(
        'Supplied VM pause release, not a native process crash.',
      );
    },
  );
  if (launch == 1 || launch == 3) {
    await expectLater(
      pending,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'pause message',
          'Supplied VM pause release, not a native process crash.',
        ),
      ),
    );
  } else {
    await pending;
  }
  final file = File('$root/launch-$launch.json');
  expect(await file.length(), lessThanOrEqualTo(8192));
  return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final (launch, stage) in [
    (1, 'reserved-paused'),
    (2, 'read-only'),
    (3, 'fresh-return-paused'),
    (4, 'fresh-read-only'),
  ]) {
    test('fixed launch $launch only accepts its declared stage authority', () {
      final raw = _challenge(launch);
      final c = NativeInitialUnresolvedChallenge.decode(jsonEncode(raw));
      expect(c.toJson(), raw);
      expect(c.stage, stage);
      expect(c.projectId, 'restart-${'a' * 32}');
      expect(c.sessionId, 'session-${'a' * 32}');
      expect(
        () => NativeInitialUnresolvedChallenge.fromJson({
          ...raw,
          'explicitNext': !c.explicitNext,
        }),
        throwsFormatException,
      );
    });
  }

  test('unknown, missing, mistyped or cross-mode challenge refuses', () {
    final valid = _challenge(1);
    for (final patch in <Map<String, Object?>>[
      {'extra': true},
      {'mode': 'initial-lineage'},
      {'mode': 'repair-lineage'},
      {'nonce': 'A' * 32},
      {'nonce': 'a' * 31},
      {'nonce': 'g' * 32},
      {'launch': 0},
      {'launch': 5},
      {'launch': true},
      {'launch': 1.0},
      {'launch': '1'},
      {'explicitNext': 0},
      {'sdk': ''},
      {'sdk': 'relative'},
      {'sdk': '/sdk/../other'},
      {'sdk': '/sdk/'},
      {'sdk': '/sdk\n'},
      {'sdk': '/sdk\u0000'},
    ]) {
      expect(
        () => NativeInitialUnresolvedChallenge.fromJson({...valid, ...patch}),
        throwsFormatException,
        reason: '$patch',
      );
    }
    for (final key in valid.keys) {
      expect(
        () =>
            NativeInitialUnresolvedChallenge.fromJson({...valid}..remove(key)),
        throwsFormatException,
      );
    }
    for (final value in [null, [], 'initial-unresolved']) {
      expect(
        () => NativeInitialUnresolvedChallenge.fromJson(value),
        throwsFormatException,
      );
    }
  });

  test('duplicate JSON members and multibyte oversize refuse before use', () {
    final raw = jsonEncode(_challenge(1));
    expect(
      () => NativeInitialUnresolvedChallenge.decode(
        raw.replaceFirst('"launch":1', '"launch":1,"launch":1'),
      ),
      throwsFormatException,
    );
    final oversized = jsonEncode({..._challenge(1), 'sdk': '/${'é' * 2050}'});
    expect(utf8.encode(oversized).length, greaterThan(4096));
    expect(
      () => NativeInitialUnresolvedChallenge.decode(oversized),
      throwsFormatException,
    );
  });

  test('literal record cohorts use production identity prefixes', () {
    final c = NativeInitialUnresolvedChallenge.fromJson(_challenge(1));
    final p = c.projectId, s = c.sessionId;
    expect(c.recordSlots, {
      'working': 'studio.generation.v1.$p',
      'requestJournal': '${SessionProposalRequestStore.prefix}$p.$s',
      'session': '${AgentSession.prefix}$p.$s',
      'candidateJournal': 'studio.candidateChecks.v1.$p',
      'candidate': 'studio.sourceCandidate.v1.$p',
      'execution': 'studio.agentExecution.v1.candidate-$p-1',
      'history': '${AgentTaskHistoryStore.prefix}$p.1',
      'context': '${CandidateReopenContext.prefix}$p.1',
      'initialCompanion': '${CandidateRequestLineage.prefix}$p.1',
      'repairCompanion': '${CandidateRepairLineage.prefix}$p.1',
    });
    expect(c.recordSlots.values.toSet(), hasLength(10));
    expect(NativeInitialUnresolvedChallenge.reportKeys, hasLength(32));
    expect(NativeInitialUnresolvedChallenge.counterKeys, hasLength(14));
  });
  for (final next in [false, true]) {
    test(
      'same-process native stages explicitNext=$next; no app crash',
      () async {
        final temp = await _privateRoot('asg-candidate-crash-vm-unresolved-');
        final root = await temp.resolveSymbolicLinks();
        await Directory('$root/sdk').create();
        try {
          final first = await _stage(root, 1);
          final original = await _physical(root);
          final second = await _stage(root, 2);
          expect(await _physical(root), original);
          expect(
            first.keys.toSet(),
            NativeInitialUnresolvedChallenge.reportKeys,
          );
          expect(first['version'], 24);
          expect(first['latestRequestStatus'], 'reserved');
          expect(first['latestResponseModel'], isNull);
          expect(first['requestReference'], isNull);
          expect(first['unresolvedReturnedSourceSha256'], isNull);
          expect((first['counters'] as Map)['reservationCommits'], 1);
          expect((first['counters'] as Map)['reservationReturns'], 0);
          expect((first['counters'] as Map)['suppliedProviderCalls'], 0);
          expect((first['counters'] as Map)['proposalReturns'], 0);
          expect(second['recordsBefore'], first['recordsAfter']);
          expect(second['recordsAfter'], second['recordsBefore']);
          expect(
            second['unresolvedRequestSha256'],
            first['unresolvedRequestSha256'],
          );
          expect(
            (second['counters'] as Map).values.every((v) => v == 0),
            isTrue,
          );
          expect(await Directory('$root/working').exists(), isFalse);
          expect(await Directory('$root/candidate').exists(), isFalse);
          await expectLater(
            runNativeInitialUnresolvedFixture(
              root,
              jsonEncode({..._challenge(1), 'sdk': '$root/sdk'}),
            ),
            throwsStateError,
          );
          expect(await _physical(root), original);
          if (next) {
            final third = await _stage(root, 3);
            final returned = await _physical(root);
            final fourth = await _stage(root, 4);
            expect(await _physical(root), returned);
            expect(third['recordsBefore'], second['recordsAfter']);
            expect(fourth['recordsBefore'], third['recordsAfter']);
            expect(fourth['recordsAfter'], fourth['recordsBefore']);
            expect(
              third['unresolvedRequestSha256'],
              first['unresolvedRequestSha256'],
            );
            expect(third['unresolvedRequestStatus'], 'reserved');
            expect(third['unresolvedResponseModel'], isNull);
            expect(third['latestRequestNumber'], 2);
            expect(third['latestRequestStatus'], 'returnedValidated');
            expect(
              third['latestResponseModel'],
              NativeInitialUnresolvedChallenge.suppliedModel,
            );
            expect(
              third['latestRequestSha256'],
              isNot(third['unresolvedRequestSha256']),
            );
            expect((third['requestReference'] as Map)['number'], 2);
            expect(third['requestReference'], fourth['requestReference']);
            expect((third['counters'] as Map)['reservationReturns'], 1);
            expect((third['counters'] as Map)['suppliedProviderCalls'], 1);
            expect((third['counters'] as Map)['terminalCommits'], 1);
            expect((third['counters'] as Map)['proposalReturns'], 1);
            expect(
              (fourth['counters'] as Map).values.every((v) => v == 0),
              isTrue,
            );
            final c = NativeInitialUnresolvedChallenge.fromJson({
              ..._challenge(1),
              'sdk': '$root/sdk',
            });
            final key = c.recordSlots['requestJournal']!;
            final old = SessionProposalRequestJournal.decode(original[key]!)
                .requests
                .single;
            final values = SessionProposalRequestJournal.decode(returned[key]!)
                .requests;
            expect(values.first.toJson(), old.toJson());
            expect(
              values.last.status,
              SessionProposalRequestStatus.returnedValidated,
            );
            expect(returned, {...original, key: returned[key]!});
          }
        } finally {
          await temp.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS && !Platform.isLinux,
    );
  }
  test(
    'cold stage refuses wrong nonce and symlink capture without writes',
    () async {
      final temp = await _privateRoot(
        'asg-candidate-crash-vm-unresolved-refusal-',
      );
      final root = await temp.resolveSymbolicLinks();
      await Directory('$root/sdk').create();
      try {
        await _stage(root, 1);
        final before = await _physical(root);
        await expectLater(_stage(root, 2, nonce: 'b' * 32), throwsStateError);
        expect(await File('$root/launch-2.json').exists(), isFalse);
        expect(await _physical(root), before);
        final capture = File('$root/capture-1.json');
        await capture.rename('$root/saved-capture.json');
        await Link(capture.path).create('$root/saved-capture.json');
        await expectLater(_stage(root, 2), throwsStateError);
        expect(await File('$root/launch-2.json').exists(), isFalse);
        expect(await _physical(root), before);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
  test(
    'broader root permissions refuse before database/report creation',
    () async {
      final temp = await _privateRoot(
        'asg-candidate-crash-vm-unresolved-mode-',
      );
      final root = await temp.resolveSymbolicLinks();
      await Directory('$root/sdk').create();
      try {
        final broaden = await Process.run('/bin/chmod', ['0755', root]);
        expect(broaden.exitCode, 0);
        SharedPreferences.setMockInitialValues({});
        await expectLater(
          runNativeInitialUnresolvedFixture(
            root,
            jsonEncode({..._challenge(1), 'sdk': '$root/sdk'}),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'privacy refusal',
              'Private canonical fixture root and existing SDK required.',
            ),
          ),
        );
        expect(await File('$root/initial-unresolved.db').exists(), isFalse);
        expect(await File('$root/launch-1.json').exists(), isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
}
