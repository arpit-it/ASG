import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/studio_session_controller.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_session_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'studio_session_controller_test.dart' show project;

const privateDetail = 'PRIVATE_PROMPT token=PRIVATE_TOKEN /private/project';

class SessionRecords implements RecordStorage {
  final values = <String, String>{};
  final writes = <String>[];
  String? failingRead;
  String? failingWrite;
  Completer<bool>? pending;
  @override
  String? getString(String key) {
    if (key == failingRead) throw StateError(privateDetail);
    return values[key];
  }

  @override
  Future<bool> setString(String key, String value) async {
    writes.add(key);
    if (key == failingWrite) throw StateError(privateDetail);
    if (pending != null) await pending!.future;
    values[key] = value;
    return true;
  }
}

void expectPrivate(StudioSessionController c) {
  expect(c.error, isNotNull);
  for (final marker in ['PRIVATE_PROMPT', 'PRIVATE_TOKEN', '/private/']) {
    expect(c.error, isNot(contains(marker)));
  }
}

void main() {
  final first = project('first');
  final second = project('second');
  late SessionRecords records;
  late StudioSessionController c;
  setUp(() {
    records = SessionRecords();
    records.values['studio.projects.v1'] = jsonEncode([first.toJson()]);
    c = StudioSessionController(StudioSessionStore(StudioStore(records)), [
      first,
    ]);
  });
  tearDown(() {
    if (!c.isDisposed) c.dispose();
  });
  test(
    'create read/write failures stay private and explicit retry saves once',
    () async {
      final original = Map.of(records.values);
      records.failingRead = 'studio.projects.v1';
      expect(await c.create(second), isFalse);
      expectPrivate(c);
      expect(records.writes, isEmpty);
      records.failingRead = null;
      records.failingWrite = 'studio.projects.v1';
      expect(await c.create(second), isFalse);
      expectPrivate(c);
      expect(c.current, same(first));
      expect(c.savedCreation, isNull);
      expect(records.values, original);
      records.failingWrite = null;
      expect(await c.create(second), isTrue);
      expect(c.error, isNull);
      expect(StudioStore(records).load().map((p) => p.id), ['first', 'second']);
    },
  );
  test(
    'selection failure is private and retry preserves saved records',
    () async {
      final original = records.values['studio.projects.v1'];
      records.failingWrite = 'studio.lastProject.v1';
      await c.select(second);
      expectPrivate(c);
      expect(c.current, same(first));
      records.failingWrite = null;
      await c.select(second);
      expect(c.current, same(second));
      expect(c.error, isNull);
      expect(records.values['studio.projects.v1'], original);
    },
  );
  test(
    'saved creation recovery is private and retries selection only',
    () async {
      records.failingWrite = 'studio.lastProject.v1';
      expect(await c.create(second), isFalse);
      expectPrivate(c);
      expect(c.error, contains('was saved but could not be opened'));
      expect(c.savedCreation, same(second));
      final saved = records.values['studio.projects.v1'];
      records.failingRead = 'studio.projects.v1';
      await c.retrySavedCreation();
      expectPrivate(c);
      expect(c.current, same(first));
      expect(c.savedCreation, same(second));
      records.failingRead = null;
      records.failingWrite = null;
      await c.retrySavedCreation();
      expect(c.current!.id, second.id);
      expect(c.savedCreation, isNull);
      expect(c.error, isNull);
      expect(records.values['studio.projects.v1'], saved);
      expect(
        records.writes.where((k) => k == 'studio.projects.v1'),
        hasLength(1),
      );
    },
  );
  test('refresh failure is private and preserves metadata until retry', () {
    records.failingRead = 'studio.projects.v1';
    c.refreshCurrent();
    expectPrivate(c);
    expect(c.current, same(first));
    records.failingRead = null;
    c.refreshCurrent();
    expect(c.current!.id, first.id);
    expect(c.error, isNull);
    expect(records.writes, isEmpty);
  });
  test(
    'disposed creation and selection failures publish no diagnostic',
    () async {
      for (final create in [true, false]) {
        final data = SessionRecords()..pending = Completer<bool>();
        final controller = StudioSessionController(
          StudioSessionStore(StudioStore(data)),
          [first],
        );
        final future = create
            ? controller.create(second)
            : controller.select(second);
        controller.dispose();
        data.pending!.completeError(StateError(privateDetail));
        await future;
        expect(controller.error, isNull);
        expect(controller.current, same(first));
        expect(controller.savedCreation, isNull);
        expect(data.values, isEmpty);
      }
    },
  );
}
