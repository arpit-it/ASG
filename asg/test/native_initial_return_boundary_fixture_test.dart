// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/models/session_proposal_request.dart';

import 'package:flutter_test/flutter_test.dart';

import '../tools/fixtures/native_initial_return_boundary.dart';

Map<String, Object> challenge() => {
  'mode': 'initial-return-boundary',
  'nonce': 'a' * 32,
  'launch': 1,
  'sdk': '/supplied/existing-sdk',
  'boundary': 'beforeCommit',
};
void main() {
  nativeTests();
  test('strict terminal boundary metadata supports only two phases and two launches', () {
    for (final boundary in ['beforeCommit', 'afterCommit']) {
      for (final launch in [1, 2]) {
        final c = NativeInitialReturnChallenge.decode(
          jsonEncode({...challenge(), 'boundary': boundary, 'launch': launch}),
        );
        expect(c.launch, launch);
        expect(c.afterCommit, boundary == 'afterCommit');
        expect(c.recordSlots.length, 10);
        expect(c.toJson(), {
          ...challenge(),
          'boundary': boundary,
          'launch': launch,
        });
      }
    }
  });
  test(
    'foreign or malformed terminal challenge cannot acquire fixture authority',
    () {
      for (final delta in <Map<String, Object>>[
        {'launch': true},
        {'launch': 0},
        {'launch': 3},
        {'launch': 1.0},
        {'nonce': 'A' * 32},
        {'boundary': 'afterReturn'},
        {'mode': 'initial-unresolved'},
        {'explicitNext': false},
        {'sdk': 'relative'},
        {'sdk': '/supplied/../sdk'},
        {'sdk': '/sdk\nforeign'},
      ]) {
        expect(
          () => NativeInitialReturnChallenge.decode(
            jsonEncode({...challenge(), ...delta}),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => NativeInitialReturnChallenge.decode(
          '{"mode":"initial-return-boundary","mode":"initial-return-boundary"}',
        ),
        throwsFormatException,
      );
      expect(
        () => NativeInitialReturnChallenge.decode(' ' * 4097),
        throwsFormatException,
      );
    },
  );
}

Future<Directory> privateRoot() async {
  final temp = await Directory.systemTemp.createTemp(
    'asg-candidate-crash-vm-return-',
  );
  final root = await temp.resolveSymbolicLinks();
  try {
    final result = await Process.run('/bin/chmod', ['0700', root]);
    expect(result.exitCode, 0);
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
    '$root/initial-return-boundary.db',
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
  final pending = runNativeInitialReturnBoundaryFixture(
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
          'one-attempt guard',
          'Request outcome persistence is unresolved. Reopen history.',
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
      'native DB terminal phase $boundary and cold read; VM hold only',
      () async {
        final temp = await privateRoot(),
            root = await temp.resolveSymbolicLinks();
        try {
          final first = await stage(root, boundary, 1),
              raw = await physical(root);
          final second = await stage(root, boundary, 2);
          expect(await physical(root), raw);
          expect(first.keys.toSet(), NativeInitialReturnChallenge.reportKeys);
          expect(
            first['requestStatus'],
            boundary == 'beforeCommit' ? 'reserved' : 'returnedValidated',
          );
          expect(first['deliveredReference'], isNull);
          expect(second['deliveredReference'], isNull);
          expect(first['retainedReference'], isNull);
          expect(
            first['validatedResponseModel'],
            NativeInitialReturnChallenge.suppliedModel,
          );
          expect(
            first['validatedReturnedSourceSha256'],
            matches(RegExp(r'^[a-f0-9]{64}$')),
          );
          expect(second['validatedResponseModel'], isNull);
          expect(second['validatedReturnedSourceSha256'], isNull);
          expect(
            first['storedResponseModel'],
            boundary == 'beforeCommit'
                ? isNull
                : NativeInitialReturnChallenge.suppliedModel,
          );
          expect(
            first['storedReturnedSourceSha256'],
            boundary == 'beforeCommit'
                ? isNull
                : first['validatedReturnedSourceSha256'],
          );
          expect(
            second['storedReturnedSourceSha256'],
            first['storedReturnedSourceSha256'],
          );
          expect(second['recordsBefore'], first['recordsAfter']);
          expect(second['recordsAfter'], second['recordsBefore']);
          expect(second['requestSha256'], first['requestSha256']);
          expect((first['counters'] as Map)['proposalReturns'], 0);
          expect((first['counters'] as Map)['terminalReturns'], 0);
          expect(
            (first['counters'] as Map)['terminalCommits'],
            boundary == 'afterCommit' ? 1 : 0,
          );
          expect(
            (second['counters'] as Map).values.every((v) => v == 0),
            isTrue,
          );
          final c = NativeInitialReturnChallenge.fromJson({
            ...challenge(),
            'sdk': '$root/sdk',
          });
          final request = SessionProposalRequestJournal.decode(
            raw[c.recordSlots['requestJournal']]!,
          ).requests.single;
          if (boundary == 'afterCommit') {
            expect((second['retainedReference'] as Map)['number'], 1);
          } else {
            expect(second['retainedReference'], isNull);
            expect(request.returnedSha256, isEmpty);
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
  test(
    'foreign phase capture refuses cold read without rewriting native records',
    () async {
      final temp = await privateRoot(),
          root = await temp.resolveSymbolicLinks();
      try {
        await stage(root, 'afterCommit', 1);
        final before = await physical(root);
        final capture = File('$root/capture-1.json');
        final data = jsonDecode(await capture.readAsString()) as Map;
        data['boundary'] = 'beforeCommit';
        await capture.writeAsString(jsonEncode(data));
        await expectLater(
          stage(root, 'afterCommit', 2),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'capture identity',
              'Capture identity changed.',
            ),
          ),
        );
        expect(await physical(root), before);
        expect(await File('$root/launch-2.json').exists(), isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
  test('corrupt native journal is refused cold and never rewritten', () async {
    final temp = await privateRoot(), root = await temp.resolveSymbolicLinks();
    try {
      await stage(root, 'beforeCommit', 1);
      final c = NativeInitialReturnChallenge.fromJson({
        ...challenge(),
        'sdk': '$root/sdk',
      });
      final db = await databaseFactoryIo.openDatabase(
        '$root/initial-return-boundary.db',
      );
      try {
        await StoreRef<String, String>('records')
            .record(c.recordSlots['requestJournal']!)
            .put(db, 'not-json');
      } finally {
        await db.close();
      }
      final before = await physical(root);
      await expectLater(stage(root, 'beforeCommit', 2), throwsStateError);
      expect(await physical(root), before);
      expect(await File('$root/launch-2.json').exists(), isFalse);
    } finally {
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS && !Platform.isLinux);
  test('existing report symlink cannot overwrite another record', () async {
    final temp = await privateRoot(), root = await temp.resolveSymbolicLinks();
    try {
      final sentinel = File('$root/untouched.txt');
      await sentinel.writeAsString('retained');
      await Link('$root/launch-1.json').create(sentinel.path);
      SharedPreferences.setMockInitialValues({});
      await expectLater(
        runNativeInitialReturnBoundaryFixture(
          root,
          jsonEncode({...challenge(), 'sdk': '$root/sdk'}),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'one-attempt guard',
            'Request outcome persistence is unresolved. Reopen history.',
          ),
        ),
      );
      expect(await sentinel.readAsString(), 'retained');
      expect(await File('$root/capture-1.json').exists(), isFalse);
    } finally {
      await temp.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS && !Platform.isLinux);
  test(
    'public root refuses before native records or report creation',
    () async {
      final temp = await privateRoot(),
          root = await temp.resolveSymbolicLinks();
      try {
        expect((await Process.run('/bin/chmod', ['0755', root])).exitCode, 0);
        await expectLater(
          runNativeInitialReturnBoundaryFixture(
            root,
            jsonEncode({...challenge(), 'sdk': '$root/sdk'}),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'private scope',
              'Private canonical fixture root and existing SDK required.',
            ),
          ),
        );
        expect(
          await File('$root/initial-return-boundary.db').exists(),
          isFalse,
        );
        expect(await File('$root/launch-1.json').exists(), isFalse);
      } finally {
        await temp.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS && !Platform.isLinux,
  );
}
