// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const project = StudioProject(
  id: 'diagnostics',
  name: 'Demo',
  description: '',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);

class ProbeProvider implements StreamingModelProvider {
  final events = StreamController<GenerationEvent>();
  bool cancelled = false;
  @override
  Stream<GenerationEvent> generateEvents(String prompt) => events.stream;
  @override
  Stream<String> generate(String prompt) => events.stream.map((e) => e.text);
  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

Future<ChatController> create(List<ProbeProvider> providers) async {
  final store = ConversationStore.fromPreferences(
    await SharedPreferences.getInstance(),
  );
  return ChatController(
    project,
    openStore: () async => store,
    createProvider: (_) => providers.removeAt(0),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'diagnostics retain stop outcome, omit private text and reset on retry',
    () async {
      final first = ProbeProvider(), second = ProbeProvider();
      final controller = await create([first, second]);
      await controller.load();
      expect(controller.requestDiagnostic, contains('No chat request active'));
      final sending = controller.send('private-prompt-sentinel');
      expect(controller.requestDiagnostic, contains('Preparing'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.requestDiagnostic, contains('request active'));
      first.events.add(const GenerationEvent.text('private-response-sentinel'));
      await Future<void>.delayed(Duration.zero);
      expect(controller.requestDiagnostic, isNot(contains('sentinel')));
      controller.cancelGeneration();
      expect(controller.requestDiagnostic, contains('Stop requested'));
      await first.events.close();
      await sending;
      expect(first.cancelled, isTrue);
      expect(controller.requestDiagnostic, contains('request stopped'));
      expect(controller.messages, hasLength(1));
      final retry = controller.send('retry');
      await Future<void>.delayed(Duration.zero);
      expect(controller.requestDiagnostic, contains('request active'));
      final statuses = <String>[];
      controller.addListener(() => statuses.add(controller.requestDiagnostic));
      second.events.add(const GenerationEvent.text('completed'));
      await second.events.close();
      await retry;
      expect(statuses.any((s) => s.contains('Saving local')), isTrue);
      expect(controller.requestDiagnostic, contains('No chat request active'));
      expect(controller.messages, hasLength(3));
      controller.dispose();
    },
  );
  test(
    'provider failures stay private, retain outcome and reset on retry',
    () async {
      for (final failure in [
        StateError('private-error-sentinel'),
        TimeoutException('private-timeout-sentinel'),
      ]) {
        SharedPreferences.setMockInitialValues({});
        final first = ProbeProvider(), second = ProbeProvider();
        final controller = await create([first, second]);
        await controller.load();
        final sending = controller.send('private-prompt-sentinel');
        await Future<void>.delayed(Duration.zero);
        first.events.add(
          const GenerationEvent.text('private-partial-sentinel'),
        );
        first.events.addError(failure);
        await first.events.close();
        await sending;
        expect(controller.error, isNot(contains('sentinel')));
        expect(controller.requestDiagnostic, isNot(contains('sentinel')));
        expect(
          controller.requestDiagnostic,
          contains(failure is TimeoutException ? 'timed out' : 'failed'),
        );
        expect(controller.messages, hasLength(1));
        expect(controller.draftResponse, isEmpty);
        expect(first.cancelled, isTrue);
        final retry = controller.send('retry');
        expect(controller.requestDiagnostic, contains('Preparing'));
        expect(controller.error, isNull);
        await Future<void>.delayed(Duration.zero);
        second.events.add(const GenerationEvent.text('complete'));
        await second.events.close();
        await retry;
        expect(
          controller.requestDiagnostic,
          contains('No chat request active'),
        );
        expect(controller.messages, hasLength(3));
        controller.dispose();
      }
    },
  );

  test(
    'provider creation failures are private and do not claim success',
    () async {
      final store = ConversationStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final controller = ChatController(
        project,
        openStore: () async => store,
        createProvider: (_) => throw StateError('private-factory-sentinel'),
      );
      await controller.load();
      expect(await controller.send('hello'), isTrue);
      expect(controller.error, isNot(contains('sentinel')));
      expect(controller.requestDiagnostic, contains('failed'));
      expect(store.load(project.id), hasLength(1));
      controller.dispose();
    },
  );

  testWidgets('timeout outcome is visible without private exception content', (
    tester,
  ) async {
    final provider = ProbeProvider();
    final controller = await create([provider]);
    await tester.pumpWidget(
      MaterialApp(
        home: ModelChat(project: project, controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    final sending = controller.send('request');
    await tester.pump();
    provider.events.addError(TimeoutException('private-timeout-sentinel'));
    await provider.events.close();
    await sending;
    await tester.pumpAndSettle();
    expect(find.textContaining('The model request timed out'), findsOneWidget);
    expect(find.textContaining('Chat request timed out'), findsOneWidget);
    expect(find.textContaining('sentinel'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat diagnostics and Stop scope fit narrow enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = await create([]);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: ModelChat(project: project, controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Chat request diagnostics'));
    await tester.tap(find.text('Chat request diagnostics'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1536 output tokens'), findsOneWidget);
    expect(
      find.textContaining('Server-side inference may continue'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
