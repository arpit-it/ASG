// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/services/requirements_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plan_task_import_test.dart' show seed;
import 'planning_conversation_test.dart'
    show ControlledRecords, PlanningProvider, chat, project;

class PrivateTaskRecords extends ControlledRecords {
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<bool> setString(String key, String value) async {
    if (key == RequirementsStore.key(project.id)) {
      await pending?.future;
      if (fail) {
        throw StateError('PRIVATE_PROMPT token=secret /private/tasks');
      }
    }
    return super.setString(key, value);
  }
}

void main() {
  test(
    'task save failure stays private and preserves evidence for retry',
    () async {
      final records = PrivateTaskRecords();
      await seed(records);
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      addTearDown(controller.dispose);
      await controller.load();
      final before = Map<String, String>.of(records.values);
      records.fail = true;
      await controller.addPlanTasks();
      expect(controller.error, contains('could not be saved'));
      for (final marker in ['PRIVATE_PROMPT', 'token=secret', '/private/']) {
        expect(controller.error, isNot(contains(marker)));
        expect(controller.requestDiagnostic, isNot(contains(marker)));
      }
      expect(records.values, before);
      expect(controller.canAddPlanTasks, true);
      records.fail = false;
      await controller.addPlanTasks();
      expect(controller.error, isNull);
      expect(RequirementsStore(records).load(project.id).tasks.length, 3);
      expect(controller.canAddPlanTasks, false);
      expect(provider.prompt, isNull);
    },
  );

  test('disposed task save failure cannot publish diagnostics', () async {
    final records = PrivateTaskRecords();
    await seed(records);
    final controller = chat(records, PlanningProvider());
    await controller.load();
    final before = Map<String, String>.of(records.values);
    records.fail = true;
    records.pending = Completer<void>();
    final saving = controller.addPlanTasks();
    controller.dispose();
    records.pending!.complete();
    await saving;
    expect(controller.error, isNull);
    expect(records.values, before);
  });
}
