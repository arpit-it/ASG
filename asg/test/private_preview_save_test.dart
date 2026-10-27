// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'interaction_persistence_test.dart' show project, initial;

class PrivatePreviewStore extends ApplicationStore {
  PrivatePreviewStore(super.records);
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<void> save(String id, ApplicationSnapshot state) async {
    await pending?.future;
    if (fail) throw StateError('PRIVATE_PROMPT token=secret /private/preview');
    await super.save(id, state);
  }
}

void main() {
  Future<PrivatePreviewStore> store() async {
    SharedPreferences.setMockInitialValues({});
    final result = PrivatePreviewStore(
      PreferenceRecords(await SharedPreferences.getInstance()),
    );
    await result.save(project.id, const ApplicationSnapshot(initial, [], 1));
    return result;
  }

  test(
    'preview save failure stays private and retains exact retry state',
    () async {
      final records = await store();
      final controller = AppWorkspaceController(
        project,
        openStore: () async => records,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final before = records.records.getString('studio.application.v1.p');
      final changed = AppDefinition(
        title: 'Changed',
        theme: initial.theme,
        elements: initial.elements,
      );
      records.fail = true;
      await controller.recordRuntimeState(changed);
      expect(controller.error, contains('Retry saving'));
      for (final marker in ['PRIVATE_PROMPT', 'token=secret', '/private/']) {
        expect(controller.error, isNot(contains(marker)));
      }
      expect(controller.hasUnsavedInteractions, true);
      expect(controller.definition, same(changed));
      expect(records.records.getString('studio.application.v1.p'), before);
      expect(await controller.saveInteractions(), false);
      expect(controller.hasUnsavedInteractions, true);
      records.fail = false;
      expect(await controller.saveInteractions(), true);
      expect(controller.error, isNull);
      expect(controller.hasUnsavedInteractions, false);
      expect(records.load(project).definition.title, 'Changed');
      expect(controller.revision, 1);
    },
  );
  test('disposed preview save failure cannot publish diagnostics', () async {
    final records = await store();
    final controller = AppWorkspaceController(
      project,
      openStore: () async => records,
    );
    await controller.load();
    final before = records.records.getString('studio.application.v1.p');
    records.fail = true;
    records.pending = Completer<void>();
    final saving = controller.recordRuntimeState(initial);
    controller.dispose();
    records.pending!.complete();
    await saving;
    expect(controller.error, isNull);
    expect(records.records.getString('studio.application.v1.p'), before);
  });
}
