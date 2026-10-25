import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/model_chat.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

const project = StudioProject(
  id: 'planning',
  name: 'Planner',
  description: 'Track weekly tasks',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);

class PlanningProvider implements StreamingModelProvider {
  final events = StreamController<GenerationEvent>();
  String? prompt;
  bool cancelled = false;
  @override
  Stream<GenerationEvent> generateEvents(String value) {
    prompt = value;
    return events.stream;
  }

  @override
  Stream<String> generate(String value) =>
      generateEvents(value).map((e) => e.text);
  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

class ControlledRecords implements RecordStorage {
  final values = <String, String>{};
  int writes = 0;
  int? failWrite;
  Completer<void>? gate;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    await gate?.future;
    if (writes == failWrite) return false;
    values[key] = value;
    return true;
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);
ChatController chat(RecordStorage records, PlanningProvider provider) =>
    ChatController(
      project,
      openStore: () async => ConversationStore(records),
      createProvider: (_) => provider,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'real local Qwen planning streams and saves a draft',
    () async {
      // Run this opt-in test alone to bypass widget-test HTTP mocking.
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final records = ControlledRecords();
      final controller = ChatController(
        project,
        openStore: () async => ConversationStore(records),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.selectMode(ConversationMode.plan);
      final drafts = <String>{};
      controller.addListener(() {
        if (controller.draftResponse.isNotEmpty) {
          drafts.add(controller.draftResponse);
        }
      });
      expect(
        await controller.send(
          'Make a concise plan for adding a weekly task view. Keep each of the requested sections to one brief line.',
        ),
        true,
      );
      expect(controller.error, isNull);
      expect(drafts.length, greaterThan(1));
      expect(
        controller.messages.last.content,
        startsWith('[Plan draft — not approved]'),
      );
      expect(
        controller.messages.last.content.toLowerCase(),
        contains('acceptance'),
      );
      expect(
        ConversationStore(records).load(project.id).last.content,
        controller.messages.last.content,
      );
      expect(records.values.keys, ['studio.chat.v1.planning']);
    },
    skip: !const bool.fromEnvironment('ASG_REAL_INFERENCE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'Plan streams labeled drafts, preserves history and cannot enable tools',
    () async {
      final records = ControlledRecords();
      final store = ConversationStore(records);
      await store.save(project.id, [
        const ChatMessage(role: 'user', content: 'Legacy question'),
      ]);
      records.values['studio.application.v1.planning'] =
          'untouched application';
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      await controller.load();
      controller.selectMode(ConversationMode.build);
      expect(controller.mode, ConversationMode.discuss);
      controller.selectMode(ConversationMode.plan);
      final sending = controller.send('Plan a weekly view');
      await tick();
      expect(provider.prompt, contains('Acceptance criteria'));
      expect(provider.prompt, contains('Feasibility and dependencies'));
      expect(provider.prompt, contains('Track weekly tasks'));
      expect(provider.prompt, contains('Legacy question'));
      expect(provider.prompt, contains('no file or command tools'));
      controller.selectMode(ConversationMode.discuss);
      expect(controller.mode, ConversationMode.plan);
      expect(await controller.send('Duplicate'), false);
      provider.events.add(
        const GenerationEvent.text('Requirements\nWeekly view.'),
      );
      await tick();
      expect(controller.draftResponse, contains('Weekly view'));
      expect(store.load(project.id), hasLength(2));
      await provider.events.close();
      expect(await sending, true);
      expect(
        store.load(project.id).last.content,
        startsWith('[Plan draft — not approved]'),
      );
      expect(controller.busy, false);
      expect(provider.cancelled, true);
      expect(
        records.values['studio.application.v1.planning'],
        'untouched application',
      );
      expect(
        records.values.keys,
        unorderedEquals([
          'studio.chat.v1.planning',
          'studio.application.v1.planning',
        ]),
      );
      final reopened = chat(records, PlanningProvider());
      await reopened.load();
      expect(reopened.mode, ConversationMode.discuss);
      expect(reopened.messages.last.content, controller.messages.last.content);
      reopened.dispose();
      controller.dispose();
    },
  );

  test('Discuss prompt stays distinct after switching from Plan', () async {
    final provider = PlanningProvider();
    final controller = chat(ControlledRecords(), provider);
    await controller.load();
    controller.selectMode(ConversationMode.plan);
    controller.selectMode(ConversationMode.discuss);
    final sending = controller.send('Clarify tasks');
    await tick();
    expect(provider.prompt, startsWith('Discuss requirements'));
    provider.events.add(const GenerationEvent.text('What tasks?'));
    await provider.events.close();
    await sending;
    expect(controller.messages.last.content, 'What tasks?');
    controller.dispose();
  });

  test('cancel before initial save completes never starts inference', () async {
    final records = ControlledRecords()..gate = Completer<void>();
    final provider = PlanningProvider();
    final controller = chat(records, provider);
    await controller.load();
    controller.selectMode(ConversationMode.plan);
    final sending = controller.send('Plan');
    controller.cancelGeneration();
    records.gate!.complete();
    expect(await sending, true);
    expect(provider.prompt, isNull);
    expect(controller.messages.single.role, 'user');
    expect(controller.busy, false);
    controller.dispose();
  });

  test('cancel and dispose never persist streamed partial plans', () async {
    for (final dispose in [false, true]) {
      final records = ControlledRecords();
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      await controller.load();
      controller.selectMode(ConversationMode.plan);
      final sending = controller.send('Plan');
      await tick();
      provider.events.add(const GenerationEvent.text('Partial'));
      await tick();
      if (dispose) {
        controller.dispose();
      } else {
        controller.cancelGeneration();
      }
      await provider.events.close();
      await sending;
      expect(ConversationStore(records).load(project.id).single.role, 'user');
      expect(controller.busy, false);
      if (!dispose) controller.dispose();
    }
  });

  test(
    'failed writes retain input or saved request without publishing a draft',
    () async {
      for (final failure in [1, 2]) {
        final records = ControlledRecords()..failWrite = failure;
        final provider = PlanningProvider();
        final controller = chat(records, provider);
        await controller.load();
        controller.selectMode(ConversationMode.plan);
        final sending = controller.send('Plan');
        await tick();
        if (failure == 2) {
          provider.events.add(const GenerationEvent.text('Draft'));
          await provider.events.close();
        }
        expect(await sending, failure == 2);
        expect(controller.messages, hasLength(failure - 1));
        expect(controller.error, contains('could not be saved'));
        expect(controller.busy, false);
        controller.dispose();
      }
    },
  );

  test('empty/error model results leave only the saved request', () async {
    for (final fail in [false, true]) {
      final records = ControlledRecords();
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      await controller.load();
      controller.selectMode(ConversationMode.plan);
      final sending = controller.send('Plan');
      await tick();
      if (fail) provider.events.addError(StateError('Offline'));
      await provider.events.close();
      await sending;
      expect(controller.error, contains(fail ? 'Offline' : 'no response'));
      expect(controller.messages.single.role, 'user');
      expect(controller.busy, false);
      controller.dispose();
    }
  });

  test('planning history survives real native database close/reopen', () async {
    final temp = await Directory.systemTemp.createTemp('asg-plan-');
    try {
      final path = '${temp.path}/plan.db';
      var db = await databaseFactoryIo.openDatabase(path);
      final prefs = await SharedPreferences.getInstance();
      var records = await StudioDatabase.migrate(db, prefs);
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      await controller.load();
      controller.selectMode(ConversationMode.plan);
      final sending = controller.send('Plan a weekly view');
      await tick();
      provider.events.add(
        const GenerationEvent.text('Requirements\nWeekly view'),
      );
      await provider.events.close();
      await sending;
      controller.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      records = await StudioDatabase.migrate(db, prefs);
      expect(
        ConversationStore(records).load(project.id).last.content,
        '[Plan draft — not approved]\nRequirements\nWeekly view',
      );
      await db.close();
    } finally {
      await temp.delete(recursive: true);
    }
  });

  testWidgets(
    'selector, streamed draft and mode locking work on a narrow screen',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = PlanningProvider();
      final controller = chat(ControlledRecords(), provider);
      await tester.pumpWidget(
        MaterialApp(
          home: ModelChat(project: project, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      expect(find.textContaining('this screen cannot approve'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Plan a weekly view');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(
        tester
            .widget<SegmentedButton<ConversationMode>>(
              find.byType(SegmentedButton<ConversationMode>),
            )
            .onSelectionChanged,
        isNull,
      );
      provider.events.add(
        const GenerationEvent.text('Requirements: weekly view'),
      );
      await tester.pump();
      expect(find.text('Requirements: weekly view'), findsOneWidget);
      await provider.events.close();
      await tester.pumpAndSettle();
      expect(
        find.textContaining('[Plan draft — not approved]'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('workspace opens and returns from Discuss and plan', (
    tester,
  ) async {
    final records = ControlledRecords();
    final controller = AppWorkspaceController(
      project,
      openStore: () async => ApplicationStore(records),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectWorkspace(project: project, controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Discuss and plan'));
    await tester.pumpAndSettle();
    expect(find.byType(ModelChat), findsOneWidget);
    await tester.tap(find.text('Plan'));
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ProjectWorkspace), findsOneWidget);
    expect(controller.revision, 1);
    expect(records.writes, 0);
    expect(tester.takeException(), isNull);
  });
  for (final finalSave in [false, true]) {
    testWidgets(
      'Back waits for ${finalSave ? 'final response' : 'initial request'} commit and reopen retains it',
      (tester) async {
        final records = ControlledRecords();
        final provider = PlanningProvider();
        ChatController? active;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) {
                      active = chat(records, provider);
                      return ModelChat(project: project, controller: active);
                    },
                  ),
                ),
                child: const Text('Open conversation'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open conversation'));
        await tester.pumpAndSettle();
        active!.selectMode(ConversationMode.plan);
        if (!finalSave) records.gate = Completer<void>();
        final sending = active!.send('Keep this plan');
        await tester.pump();
        if (finalSave) {
          records.gate = Completer<void>();
          provider.events.add(
            const GenerationEvent.text('Requirements: preserved'),
          );
          unawaited(provider.events.close());
          await tester.pump();
          expect(active!.phase, GenerationPhase.applying);
          expect(find.text('Saving response…'), findsWidgets);
          active!.cancelGeneration();
          expect(active!.cancelled, false);
        }
        final back = tester.widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == 'Back',
          ),
        );
        expect(back.onPressed, isNull);
        await Navigator.of(tester.element(find.byType(ModelChat))).maybePop();
        await tester.pump();
        expect(find.byType(ModelChat), findsOneWidget);
        records.gate!.complete();
        await tester.pump();
        if (!finalSave) {
          provider.events.add(
            const GenerationEvent.text('Requirements: preserved'),
          );
          unawaited(provider.events.close());
        }
        await tester.pumpAndSettle();
        expect(await sending, true);
        expect(active!.messages, hasLength(2));
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('Open conversation'), findsOneWidget);
        await tester.tap(find.text('Open conversation'));
        await tester.pumpAndSettle();
        expect(active!.messages, hasLength(2));
        expect(
          active!.messages.last.content,
          contains('Requirements: preserved'),
        );
        expect(active!.mode, ConversationMode.discuss);
        expect(records.writes, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'Plan scrolls on a small screen with enlarged text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = chat(ControlledRecords(), PlanningProvider());
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(1.5),
              viewInsets: const EdgeInsets.only(bottom: 250),
            ),
            child: child!,
          ),
          home: ModelChat(project: project, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'A short plan');
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'A short plan',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
