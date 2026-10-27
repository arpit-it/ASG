// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/project_details_controller.dart';
import 'package:asg/controllers/studio_session_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/project_details_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_session_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/project_details_dialog.dart';
import 'package:asg/views/studio_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const original = StudioProject(
  id: 'details',
  name: 'Original',
  description: 'A simple welcome page',
  type: 'Flutter',
  platforms: ['Web', 'macOS'],
  location: '/existing/project',
);
const appKey = 'studio.application.v1.details';
const projectKey = 'studio.projects.v1';

class Records implements RecordStorage {
  final values = <String, String>{};
  final writes = <String>[];
  String? failKey, delayKey;
  Completer<void>? gate;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    writes.add(key);
    if (key == delayKey) await gate!.future;
    if (key == failKey) return false;
    values[key] = value;
    return true;
  }
}

void main() {
  late Records records;
  late StudioStore projects;
  late ProjectDetailsController controller;
  setUp(() async {
    records = Records();
    projects = StudioStore(records);
    await projects.save([original]);
    records.writes.clear();
    controller = ProjectDetailsController(
      original,
      ProjectDetailsStore(projects),
    );
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });

  test(
    'save preserves starter before metadata, other fields and export identity',
    () async {
      final applications = ApplicationStore(records);
      final before = applications.load(original);
      final input = GenerationInput(original, before.definition);
      final saved = GeneratedProject(
        directory: '/snapshot',
        sdk: '/sdk',
        python: 'python3',
        sources: input.fingerprints,
      );
      expect(await controller.save(' Renamed ', ' A task planner '), isTrue);
      final reopened = projects.load().single;
      expect(reopened.name, 'Renamed');
      expect(reopened.description, 'A task planner');
      expect(reopened.id, original.id);
      expect(reopened.type, original.type);
      expect(reopened.platforms, original.platforms);
      expect(reopened.location, original.location);
      expect(records.writes, [appKey, projectKey]);
      final restored = applications.load(reopened);
      expect(restored.definition.toJson(), before.definition.toJson());
      expect(restored.messages, isEmpty);
      expect(restored.revision, before.revision);
      expect(
        GenerationInput(reopened, restored.definition).compare(saved),
        GeneratedSnapshotStatus.outdated,
      );
      expect(input.compare(saved), GeneratedSnapshotStatus.current);
    },
  );

  test('existing application, interaction state, revision and chat stay byte-identical', () async {
    final app = ApplicationStore(records);
    const definition = AppDefinition(
      title: 'Actual app',
      theme: 'green',
      elements: [
        AppElement(
          id: 'counter',
          kind: ElementKind.counter,
          label: 'Count',
          value: '7',
        ),
        AppElement(
          id: 'notes',
          kind: ElementKind.notes,
          label: 'Notes',
          value: 'Keep this',
        ),
      ],
    );
    await app.save(
      original.id,
      const ApplicationSnapshot(definition, [
        ChatMessage(role: 'user', content: 'Keep my conversation'),
      ], 9),
    );
    final raw = records.values[appKey];
    records.writes.clear();
    expect(await controller.save('Renamed', 'Different requirements'), isTrue);
    expect(records.writes, [projectKey]);
    expect(records.values[appKey], raw);
    expect(app.load(projects.load().single).revision, 9);
  });

  test('invalid name and blank requirements never write', () async {
    for (final name in ['', '  ', 'a/b', r'a\b', 'a\nb']) {
      expect(await controller.save(name, 'Requirements'), isFalse);
      expect(controller.error, isNotNull);
    }
    expect(await controller.save('Valid', '   '), isFalse);
    expect(controller.error, contains('Describe'));
    expect(records.writes, isEmpty);
  });

  test('failed starter preservation prevents metadata update', () async {
    final raw = records.values[projectKey];
    records.failKey = appKey;
    expect(await controller.save('Changed', 'Requirements'), isFalse);
    expect(records.values[projectKey], raw);
    expect(records.writes, [appKey]);
    expect(controller.project, same(original));
    expect(controller.busy, isFalse);
  });

  test(
    'failed metadata write retains original and retries without replacing app',
    () async {
      final raw = records.values[projectKey];
      records.failKey = projectKey;
      expect(await controller.save('Changed', 'Requirements'), isFalse);
      expect(records.values[projectKey], raw);
      expect(controller.project, same(original));
      expect(controller.error, contains('could not be saved'));
      final frozen = records.values[appKey];
      records.failKey = null;
      expect(await controller.save('Changed', 'Requirements'), isTrue);
      expect(controller.error, isNull);
      expect(records.values[appKey], frozen);
    },
  );

  test(
    'missing duplicate stale and corrupt records fail without overwriting',
    () async {
      final changed = StudioProject(
        id: original.id,
        name: 'Other writer',
        description: original.description,
        type: original.type,
        platforms: original.platforms,
        location: original.location,
      );
      for (final all in [
        <StudioProject>[],
        [original, original],
        [changed],
      ]) {
        await projects.save(all);
        records.writes.clear();
        final raw = records.values[projectKey];
        expect(await controller.save('Changed', 'Requirements'), isFalse);
        expect(records.values[projectKey], raw);
        expect(records.writes, isEmpty);
      }
      await projects.save([original]);
      records.values[appKey] = 'corrupt';
      records.writes.clear();
      expect(await controller.save('Changed', 'Requirements'), isFalse);
      expect(records.values[appKey], 'corrupt');
      expect(records.writes, isEmpty);
    },
  );

  test(
    'rereads metadata after starter write and preserves unrelated projects',
    () async {
      records.delayKey = appKey;
      records.gate = Completer<void>();
      final save = controller.save('Changed', 'Requirements');
      const other = StudioProject(
        id: 'other',
        name: 'Other',
        description: 'Other',
        type: 'Flutter',
        platforms: ['Web'],
        location: '',
      );
      await projects.save([original, other]);
      records.gate!.complete();
      expect(await save, isTrue);
      expect(projects.load().last.toJson(), other.toJson());
    },
  );

  test('changed original during starter save cannot be overwritten', () async {
    records.delayKey = appKey;
    records.gate = Completer<void>();
    final saving = controller.save('Changed', 'Requirements');
    final replacement = StudioProject(
      id: original.id,
      name: 'Other writer',
      description: original.description,
      type: original.type,
      platforms: original.platforms,
      location: original.location,
    );
    await projects.save([replacement]);
    records.gate!.complete();
    expect(await saving, isFalse);
    expect(projects.load().single.name, 'Other writer');
    expect(controller.error, contains('Reopen'));
  });

  test(
    'busy and disposed workflows cannot start more writes or publish late',
    () async {
      records.delayKey = appKey;
      records.gate = Completer<void>();
      final saving = controller.save('Changed', 'Requirements');
      expect(controller.busy, isTrue);
      expect(await controller.save('Other', 'Requirements'), isFalse);
      controller.dispose();
      records.gate!.complete();
      expect(await saving, isFalse);
      expect(controller.project, same(original));
      expect(records.writes, [appKey]);
      expect(await controller.save('Other', 'Requirements'), isFalse);
    },
  );

  test(
    'dispose during metadata commit keeps durable result but never publishes',
    () async {
      await ApplicationStore(records)
          .save(original.id, ApplicationStore(records).load(original));
      records.delayKey = projectKey;
      records.gate = Completer<void>();
      final saving = controller.save('Changed', 'Requirements');
      await Future<void>.delayed(Duration.zero);
      controller.dispose();
      records.gate!.complete();
      expect(await saving, isFalse);
      expect(controller.project, same(original));
      expect(projects.load().single.name, 'Changed');
    },
  );

  test(
    'session refresh publishes saved metadata without changing selection',
    () async {
      records.values['studio.lastProject.v1'] = original.id;
      final session = StudioSessionController(StudioSessionStore(projects), [
        original,
      ]);
      expect(await controller.save('Changed', 'Requirements'), isTrue);
      records.writes.clear();
      session.refreshCurrent();
      expect(session.current!.name, 'Changed');
      expect(records.values['studio.lastProject.v1'], original.id);
      expect(records.writes, isEmpty);
      session.dispose();
    },
  );

  testWidgets(
    'editor retains input after failure and disables close while saving',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) => ProjectDetailsDialog(controller: controller),
              ),
              child: const Text('Edit'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Original'),
        'Changed',
      );
      records.failKey = projectKey;
      records.delayKey = appKey;
      records.gate = Completer<void>();
      await tester.tap(find.text('Save details'));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<PopScope>(find.byType(PopScope).last).canPop,
        isFalse,
      );
      records.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Changed'), findsOneWidget);
      expect(find.textContaining('could not be saved'), findsOneWidget);
      records.failKey = null;
      await tester.tap(find.text('Save details'));
      await tester.pumpAndSettle();
      expect(find.text('Project details'), findsNothing);
      expect(projects.load().single.name, 'Changed');
    },
  );

  testWidgets(
    'home updates header while retaining live prototype across editor and reopen',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: StudioHome(store: projects, projects: [original]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Edit project details'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Original'),
        'Renamed',
      );
      await tester.enterText(
        find.widgetWithText(TextField, original.description),
        'A task planner',
      );
      await tester.tap(find.text('Save details'));
      await tester.pumpAndSettle();
      expect(find.text('Renamed'), findsOneWidget);
      expect(
        ApplicationStore(records).load(projects.load().single).definition.title,
        'Original',
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: StudioHome(store: projects, projects: projects.load()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Renamed'), findsOneWidget);
      expect(find.byTooltip('Edit project details'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'details editor is unavailable while preview changes are saving',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const definition = AppDefinition(
        title: 'Counter app',
        theme: 'green',
        elements: [
          AppElement(
            id: 'count',
            kind: ElementKind.counter,
            label: 'Count',
            value: '0',
          ),
        ],
      );
      await ApplicationStore(records)
          .save(original.id, const ApplicationSnapshot(definition, [], 1));
      records.delayKey = appKey;
      records.gate = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: StudioHome(store: projects, projects: [original]),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Increase Count'));
      await tester.pump();
      final edit = find.byWidgetPredicate(
        (w) => w is IconButton && w.tooltip == 'Edit project details',
      );
      expect(tester.widget<IconButton>(edit).onPressed, isNull);
      records.gate!.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<IconButton>(edit).onPressed, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
