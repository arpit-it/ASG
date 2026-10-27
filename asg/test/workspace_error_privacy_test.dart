import 'dart:async';

import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/application_editor.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'interaction_persistence_test.dart' show project, initial;

const privateDetail = 'PRIVATE_PROMPT token=secret /private/workspace';

class FailingWorkspaceStore extends ApplicationStore {
  FailingWorkspaceStore(super.records);
  bool failLoad = false, failSave = false;
  @override
  ApplicationSnapshot load(project) {
    if (failLoad) throw StateError(privateDetail);
    return super.load(project);
  }

  @override
  Future<void> save(String id, ApplicationSnapshot state) async {
    if (failSave) throw StateError(privateDetail);
    await super.save(id, state);
  }
}

class FailingWorkspaceEditor extends ApplicationEditor {
  Completer<ApplicationUpdate>? pending;
  @override
  Future<ApplicationUpdate> apply(
    LocalModelConfig config,
    AppDefinition current,
    String instruction, {
    void Function(GenerationEvent)? onProgress,
  }) async {
    if (pending != null) return pending!.future;
    throw const FormatException(privateDetail, privateDetail);
  }
}

void main() {
  Future<FailingWorkspaceStore> store() async {
    SharedPreferences.setMockInitialValues({});
    final result = FailingWorkspaceStore(
      PreferenceRecords(await SharedPreferences.getInstance()),
    );
    await result.save(project.id, const ApplicationSnapshot(initial, [], 7));
    return result;
  }

  void privateError(AppWorkspaceController controller) {
    expect(controller.error, isNotNull);
    for (final marker in ['PRIVATE_PROMPT', 'token=secret', '/private/']) {
      expect(controller.error, isNot(contains(marker)));
    }
  }

  test(
    'open and load failures stay private; retry restores saved state',
    () async {
      final records = await store();
      var failOpen = true;
      final controller = AppWorkspaceController(
        project,
        openStore: () async {
          if (failOpen) throw StateError(privateDetail);
          return records;
        },
      );
      addTearDown(controller.dispose);
      final before = records.records.getString('studio.application.v1.p');
      await controller.load();
      privateError(controller);
      expect(controller.definition, isNull);
      failOpen = false;
      records.failLoad = true;
      await controller.load();
      privateError(controller);
      expect(controller.definition, isNull);
      records.failLoad = false;
      await controller.load();
      expect(controller.error, isNull);
      expect(controller.definition!.title, initial.title);
      expect(controller.revision, 7);
      expect(records.records.getString('studio.application.v1.p'), before);
    },
  );

  test('late disposed open failure cannot publish error', () async {
    final pending = Completer<ApplicationStore>();
    final controller = AppWorkspaceController(
      project,
      openStore: () => pending.future,
    );
    final loading = controller.load();
    controller.dispose();
    pending.completeError(StateError(privateDetail));
    await loading;
    expect(controller.error, isNull);
  });

  test(
    'editor and save failures preserve working state and stay private',
    () async {
      final records = await store();
      final before = records.records.getString('studio.application.v1.p');
      final editor = FailingWorkspaceEditor();
      final controller = AppWorkspaceController(
        project,
        openStore: () async => records,
        editor: editor,
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(await controller.apply('change layout'), false);
      privateError(controller);
      expect(controller.revision, 7);
      expect(controller.messages, isEmpty);
      expect(controller.definition!.title, initial.title);
      expect(records.records.getString('studio.application.v1.p'), before);
      editor.pending = Completer<ApplicationUpdate>()
        ..complete(const ApplicationUpdate(initial, 'Updated'));
      records.failSave = true;
      expect(await controller.apply('change layout'), false);
      privateError(controller);
      expect(controller.revision, 7);
      expect(controller.messages, isEmpty);
      expect(records.records.getString('studio.application.v1.p'), before);
      records.failSave = false;
      expect(await controller.apply('change layout'), true);
      expect(controller.error, isNull);
      expect(controller.revision, 8);
    },
  );

  for (final dispose in [false, true]) {
    test(
      'late edit failure after ${dispose ? 'disposal' : 'cancellation'}',
      () async {
        final records = await store();
        final before = records.records.getString('studio.application.v1.p');
        final editor = FailingWorkspaceEditor()
          ..pending = Completer<ApplicationUpdate>();
        final controller = AppWorkspaceController(
          project,
          openStore: () async => records,
          editor: editor,
        );
        await controller.load();
        final editing = controller.apply('change layout');
        await Future<void>.delayed(Duration.zero);
        if (dispose) {
          controller.dispose();
        } else {
          controller.cancelGeneration();
        }
        editor.pending!.completeError(StateError(privateDetail));
        expect(await editing, false);
        if (dispose) {
          expect(controller.error, isNull);
        } else {
          privateError(controller);
          expect(controller.error, contains('cancelled'));
          controller.dispose();
        }
        expect(controller.revision, 7);
        expect(records.records.getString('studio.application.v1.p'), before);
      },
    );
  }
}
