import 'dart:async';

import 'package:asg/controllers/requirements_controller.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:flutter_test/flutter_test.dart';

const requirement = ProjectRequirement(
  id: 'R1',
  title: 'Feature',
  acceptance: 'Survives restart',
);

class FailingRecords implements RecordStorage {
  final values = <String, String>{};
  bool failRead = false, failWrite = false;
  int writes = 0;
  Completer<void>? gate;
  @override
  String? getString(String key) {
    if (failRead) {
      throw StateError('PRIVATE_PROMPT secret-token /private/project');
    }
    return values[key];
  }

  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    await gate?.future;
    if (failWrite) {
      throw FormatException(
        'PRIVATE_PROMPT secret-token /private/project',
        value,
      );
    }
    values[key] = value;
    return true;
  }
}

void main() {
  test('board read errors stay private, retain bytes and recover', () async {
    final records = FailingRecords();
    final c = RequirementsController('project', RequirementsStore(records))
      ..load();
    addTearDown(c.dispose);
    expect(await c.saveRequirement(requirement), isTrue);
    final saved = Map.of(records.values);
    final writes = records.writes;
    records.failRead = true;
    for (var i = 0; i < 2; i++) {
      c.load();
      expect(c.board, isNull);
      expect(c.error, isNot(contains('PRIVATE_PROMPT')));
      expect(c.error, contains('Retry'));
      expect(await c.saveRequirement(requirement), isFalse);
    }
    expect(records.values, saved);
    expect(records.writes, writes);
    records.failRead = false;
    c.load();
    expect(c.error, isNull);
    expect(c.board!.requirements.single.id, 'R1');
  });
  test(
    'board write errors retain revision, retry and graph validation',
    () async {
      final records = FailingRecords();
      final c = RequirementsController('project', RequirementsStore(records))
        ..load();
      addTearDown(c.dispose);
      final original = c.board;
      records.failWrite = true;
      expect(await c.saveRequirement(requirement), isFalse);
      expect(c.error, isNot(contains('PRIVATE_PROMPT')));
      expect(c.error, contains('Reopen'));
      expect(c.board, same(original));
      expect(c.busy, isFalse);
      expect(records.values, isEmpty);
      records.failWrite = false;
      expect(await c.saveRequirement(requirement), isTrue);
      expect(c.error, isNull);
      expect(c.board!.revision, 1);
      final reopened = RequirementsController(
        'project',
        RequirementsStore(records),
      )..load();
      addTearDown(reopened.dispose);
      expect(reopened.board!.requirements.length, 1);
      final saved = Map.of(records.values);
      final writes = records.writes;
      expect(
        await c.saveTask(
          DevelopmentTask(
            id: 'T1',
            requirementId: 'R1',
            title: 'Task',
            dependencies: ['T1'],
          ),
        ),
        isFalse,
      );
      expect(c.error, contains('cycles'));
      expect(records.values, saved);
      expect(records.writes, writes);
    },
  );
  test('late failed save and reads after disposal remain silent', () async {
    final records = FailingRecords()..failWrite = true;
    final c = RequirementsController('project', RequirementsStore(records))
      ..load();
    var notifications = 0;
    c.addListener(() => notifications++);
    records.gate = Completer<void>();
    final saving = c.saveRequirement(requirement);
    final before = notifications;
    c.dispose();
    records.gate!.complete();
    expect(await saving, isFalse);
    c.load();
    expect(notifications, before);
    expect(c.error, isNull);
    expect(c.board!.revision, 0);
    expect(records.values, isEmpty);
  });
}
