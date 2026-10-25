import 'dart:async';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/conversation_mode.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'planning_conversation_test.dart'
    show project, ControlledRecords, PlanningProvider, tick, chat;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final mode in [ConversationMode.discuss, ConversationMode.plan]) {
    test('${mode.label} save retry retains output without inference', () async {
      final records = ControlledRecords()..failWrite = 2;
      final provider = PlanningProvider();
      var calls = 0;
      final controller = ChatController(
        project,
        openStore: () async => ConversationStore(records),
        createProvider: (_) {
          calls++;
          return provider;
        },
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.selectMode(mode);
      final sending = controller.send('Request');
      await tick();
      provider.events.add(const GenerationEvent.text('Complete response'));
      await provider.events.close();
      expect(await sending, true);
      expect(controller.messages, hasLength(1));
      expect(
        controller.unsavedResponse!.content,
        mode.labelResponse('Complete response'),
      );
      expect(ConversationStore(records).load(project.id), hasLength(1));
      expect(await controller.send('Must not run'), false);
      controller.selectMode(
        mode == ConversationMode.plan
            ? ConversationMode.discuss
            : ConversationMode.plan,
      );
      expect(controller.mode, mode);
      await controller.load();
      expect(controller.hasUnsavedResponse, true);
      records.failWrite = 3;
      await controller.retrySavingResponse();
      expect(controller.hasUnsavedResponse, true);
      expect(controller.error, contains('could not be saved'));
      records.gate = Completer<void>();
      final retry = controller.retrySavingResponse();
      expect(controller.busy, true);
      expect(controller.phase, GenerationPhase.applying);
      controller.cancelGeneration();
      expect(controller.cancelled, false);
      await controller.retrySavingResponse();
      expect(records.writes, 4);
      records.gate!.complete();
      await retry;
      expect(controller.hasUnsavedResponse, false);
      expect(controller.error, isNull);
      expect(controller.messages, hasLength(2));
      expect(
        ConversationStore(records).load(project.id).last.content,
        mode.labelResponse('Complete response'),
      );
      await controller.retrySavingResponse();
      expect(records.writes, 4);
      expect(calls, 1);
      expect(records.values.keys, ['studio.chat.v1.planning']);
    });
  }

  test(
    'disposed retry never publishes pending save or starts another retry',
    () async {
      final records = ControlledRecords()..failWrite = 2;
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      await controller.load();
      final sending = controller.send('Request');
      await tick();
      provider.events.add(const GenerationEvent.text('Keep this'));
      await provider.events.close();
      await sending;
      records.gate = Completer<void>();
      final retry = controller.retrySavingResponse();
      controller.dispose();
      records.gate!.complete();
      await retry;
      expect(controller.messages, hasLength(1));
      await controller.retrySavingResponse();
      expect(records.writes, 3);
      expect(ConversationStore(records).load(project.id), hasLength(2));
    },
  );

  testWidgets('save retry retains Plan response and restores navigation', (
    tester,
  ) async {
    final records = ControlledRecords()..failWrite = 2;
    final provider = PlanningProvider();
    final controller = chat(records, provider);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    ModelChat(project: project, controller: controller),
              ),
            ),
            child: const Text('Open chat'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Plan'));
    await tester.enterText(find.byType(TextField), 'Make a plan');
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    provider.events.add(const GenerationEvent.text('Recovered plan'));
    await provider.events.close();
    await tester.pumpAndSettle();
    expect(
      find.text('[Plan draft — not approved]\nRecovered plan'),
      findsOneWidget,
    );
    expect(find.text('Response not saved yet'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Back',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, false);
    expect(ConversationStore(records).load(project.id), hasLength(1));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry saving response'));
    await tester.pumpAndSettle();
    expect(find.text('Response not saved yet'), findsNothing);
    expect(
      find.text('[Plan draft — not approved]\nRecovered plan'),
      findsOneWidget,
    );
    expect(ConversationStore(records).load(project.id), hasLength(2));
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Open chat'), findsOneWidget);
  });
}
