// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_test/flutter_test.dart';

import '../tools/fixtures/native_repair_return_boundary.dart';

Map<String, Object> challenge() => {
  'mode': 'repair-return-boundary',
  'nonce': 'a' * 32,
  'launch': 1,
  'sdk': '/supplied/existing-sdk',
  'boundary': 'beforeCommit',
};
void main() {
  nativeTests();
  test('repair terminal metadata admits only two phases and two launches', () {
    for (final phase in ['beforeCommit', 'afterCommit']) {
      for (final launch in [1, 2]) {
        final value = {...challenge(), 'boundary': phase, 'launch': launch};
        final c = NativeRepairReturnChallenge.decode(jsonEncode(value));
        expect(c.toJson(), value);
        expect(c.afterCommit, phase == 'afterCommit');
        expect(c.recordSlots.length, 11);
        expect(NativeRepairReturnChallenge.reportKeys.length, 32);
        expect(NativeRepairReturnChallenge.counterKeys.length, 17);
        expect(NativeRepairReturnChallenge.protocolVersion, 26);
      }
    }
  });
  test(
    'repair challenge refuses foreign, mixed, duplicate and oversized metadata',
    () {
      for (final delta in <Map<String, Object>>[
        {'launch': true},
        {'launch': 0},
        {'launch': 3},
        {'launch': 1.0},
        {'nonce': 'A' * 32},
        {'boundary': 'afterReturn'},
        {'mode': 'initial-return-boundary'},
        {'retry': true},
        {'sdk': 'relative'},
        {'sdk': '/a/../sdk'},
        {'sdk': '/sdk\nforeign'},
        {'sdk': '/${'é' * 2100}'},
      ]) {
        expect(
          () => NativeRepairReturnChallenge.decode(
            jsonEncode({...challenge(), ...delta}),
          ),
          throwsFormatException,
        );
      }
      final duplicate = jsonEncode(challenge())
          .replaceFirst('"mode":', '"mode":"repair-return-boundary","mode":');
      expect(
        () => NativeRepairReturnChallenge.decode(duplicate),
        throwsFormatException,
      );
      expect(
        () => NativeRepairReturnChallenge.decode(' ' * 4097),
        throwsFormatException,
      );
    },
  );
}

Future<Directory> privateRoot() async {
  final temp = await Directory.systemTemp.createTemp(
    'asg-candidate-crash-vm-repair-return-',
  );
  final root = await temp.resolveSymbolicLinks();
  try {
    expect((await Process.run('/bin/chmod', ['0700', root])).exitCode, 0);
    expect((await Directory(root).stat()).mode & 0x3f, 0);
    await Directory('$root/sdk').create();
    return temp;
  } catch (_) {
    await temp.delete(recursive: true);
    rethrow;
  }
}

Future<Map<String, String>> physical(String root) async {
  final db = await databaseFactoryIo.openDatabase(
    '$root/repair-return-boundary.db',
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

Future<Map<String, dynamic>> stage(
  String root,
  String boundary,
  int launch,
) async {
  SharedPreferences.setMockInitialValues({});
  final pending = runNativeRepairReturnBoundaryFixture(
    root,
    jsonEncode({
      ...challenge(),
      'sdk': '$root/sdk',
      'boundary': boundary,
      'launch': launch,
    }),
    holdAfterReport: () async {
      throw StateError('Supplied VM hold release; not native crash.');
    },
  );
  if (launch == 1) {
    await expectLater(
      pending,
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'VM hold',
          'Supplied VM hold release; not native crash.',
        ),
      ),
    );
  } else {
    await pending;
  }
  return jsonDecode(await File('$root/launch-$launch.json').readAsString())
      as Map<String, dynamic>;
}

void nativeTests() {
  for (final boundary in ['beforeCommit', 'afterCommit']) {
    test(
      'repair native DB phase $boundary and cold read; VM hold only',
      () async {
        final temp = await privateRoot(),
            root = await temp.resolveSymbolicLinks();
        try {
          final a = await stage(root, boundary, 1),
              raw = await physical(root),
              b = await stage(root, boundary, 2);
          expect(await physical(root), raw);
          expect(a.keys.toSet(), NativeRepairReturnChallenge.reportKeys);
          expect(
            a['attemptStatus'],
            boundary == 'beforeCommit' ? 'reserved' : 'proposed',
          );
          expect(a['deliveredReference'], isNull);
          expect(b['deliveredReference'], isNull);
          expect(a['retainedReference'], isNull);
          expect(
            a['validatedResponseModel'],
            NativeRepairReturnChallenge.suppliedModel,
          );
          expect(
            a['validatedProposalSha256'],
            matches(RegExp(r'^[a-f0-9]{64}$')),
          );
          expect(b['validatedResponseModel'], isNull);
          expect(b['validatedProposalSha256'], isNull);
          expect(
            a['storedResponseModel'],
            boundary == 'beforeCommit'
                ? isNull
                : NativeRepairReturnChallenge.suppliedModel,
          );
          expect(
            a['storedProposalSha256'],
            boundary == 'beforeCommit' ? isNull : a['validatedProposalSha256'],
          );
          expect(b['storedProposalSha256'], a['storedProposalSha256']);
          expect(b['originSha256'], a['originSha256']);
          expect(b['failureSha256'], a['failureSha256']);
          expect(b['attemptSha256'], a['attemptSha256']);
          expect(b['recordsBefore'], a['recordsAfter']);
          expect(b['recordsAfter'], b['recordsBefore']);
          expect((a['counters'] as Map)['proposalReturns'], 0);
          expect((a['counters'] as Map)['terminalReturns'], 0);
          expect(
            (a['counters'] as Map)['terminalCommits'],
            boundary == 'afterCommit' ? 1 : 0,
          );
          expect((b['counters'] as Map).values.every((v) => v == 0), isTrue);
          expect(
            b['retainedReference'],
            boundary == 'beforeCommit' ? isNull : isNotNull,
          );
          if (boundary == 'afterCommit') {
            final ref = b['retainedReference'] as Map;
            expect(ref['attemptNumber'], 1);
            expect(ref['attemptSha256'], b['attemptSha256']);
            expect(ref['originSha256'], b['originSha256']);
          }
          expect(await Directory('$root/working').exists(), isFalse);
          expect(await Directory('$root/candidate').exists(), isFalse);
        } finally {
          await temp.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS && !Platform.isLinux,
    );
  }
  for (final damaged in ['repairOrigin', 'repairJournal']) {
    test(
      'damaged $damaged refuses cold repair without rewriting records',
      () async {
        final temp = await privateRoot(),
            root = await temp.resolveSymbolicLinks();
        try {
          await stage(root, 'afterCommit', 1);
          final c = NativeRepairReturnChallenge.fromJson({
            ...challenge(),
            'sdk': '$root/sdk',
          });
          final db = await databaseFactoryIo.openDatabase(
            '$root/repair-return-boundary.db',
          );
          try {
            await StoreRef<String, String>('records')
                .record(c.recordSlots[damaged]!)
                .put(db, 'not-json');
          } finally {
            await db.close();
          }
          final raw = await physical(root);
          await expectLater(
            stage(root, 'afterCommit', 2),
            throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
          );
          expect(await physical(root), raw);
          expect(await File('$root/launch-2.json').exists(), isFalse);
        } finally {
          await temp.delete(recursive: true);
        }
      },
      skip: !Platform.isMacOS && !Platform.isLinux,
    );
  }
  test(
    'foreign repair capture phase refuses without rewriting records',
    () async {
      final temp = await privateRoot(),
          root = await temp.resolveSymbolicLinks();
      try {
        await stage(root, 'afterCommit', 1);
        final raw = await physical(root);
        final f = File('$root/capture-1.json');
        final value = jsonDecode(await f.readAsString()) as Map;
        value['boundary'] = 'beforeCommit';
        await f.writeAsString(jsonEncode(value));
        await expectLater(
          stage(root, 'afterCommit', 2),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'capture phase',
              'Repair capture identity changed.',
            ),
          ),
        );
        expect(await physical(root), raw);
        expect(await File('$root/launch-2.json').exists(), isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
  test(
    'repair fixture refuses nonprivate root before database creation',
    () async {
      final temp = await privateRoot(),
          root = await temp.resolveSymbolicLinks();
      try {
        expect((await Process.run('/bin/chmod', ['0755', root])).exitCode, 0);
        await expectLater(
          runNativeRepairReturnBoundaryFixture(
            root,
            jsonEncode({...challenge(), 'sdk': '$root/sdk'}),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'private root',
              'Private canonical fixture root and existing SDK required.',
            ),
          ),
        );
        expect(await File('$root/repair-return-boundary.db').exists(), isFalse);
        expect(await File('$root/launch-1.json').exists(), isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
  test(
    'repair fixture refuses existing report symlink without touching target',
    () async {
      final temp = await privateRoot(),
          root = await temp.resolveSymbolicLinks();
      try {
        final sentinel = File('$root/untouched');
        await sentinel.writeAsString('retained');
        await Link('$root/launch-1.json').create(sentinel.path);
        SharedPreferences.setMockInitialValues({});
        await expectLater(
          runNativeRepairReturnBoundaryFixture(
            root,
            jsonEncode({...challenge(), 'sdk': '$root/sdk'}),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'fresh report',
              'Fresh repair report required.',
            ),
          ),
        );
        expect(await sentinel.readAsString(), 'retained');
        expect(await File('$root/capture-1.json').exists(), isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
}
