import 'dart:async';

import 'package:asg/controllers/source_review_controller.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/views/source_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart'
    show seed, serviceFor, originals, response;
import 'planning_conversation_test.dart' show ControlledRecords, project, tick;
import 'source_edit_proposer_test.dart' show FakeProvider;

void main() {
  late ControlledRecords records;
  late FakeProvider provider;
  late SourceReviewController controller;
  var reads = 0;
  SourceReviewController create({Completer<Map<String, String>>? capture}) =>
      SourceReviewController(
        project: project,
        generated: GeneratedProject(
          directory: '/saved',
          sdk: '',
          python: '',
          sources: {'lib/main.dart': 'hash'},
        ),
        records: records,
        proposer: serviceFor(records, provider),
        readSnapshot: (_, paths) async {
          reads++;
          expect(paths, ['lib/main.dart']);
          return capture == null ? originals : capture.future;
        },
      );
  setUp(() async {
    records = ControlledRecords();
    await seed(records);
    provider = FakeProvider();
    reads = 0;
    controller = create();
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });

  test('request binds selected files and task without durable writes; stale evidence hides', () async {
    final writes = records.writes;
    final pending = controller.request('Tanalyze', ['lib/main.dart']);
    await tick();
    expect(controller.busy, isTrue);
    expect(controller.status, contains('local model'));
    await controller.request('Tanalyze', ['lib/main.dart']);
    expect(reads, 1);
    provider.stream.add(response());
    await provider.stream.close();
    await pending;
    expect(
      controller.proposal!.proposal.changes.single.before,
      originals.values.single,
    );
    expect(records.writes, writes);
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    expect(controller.proposal, isNull);
    expect(controller.stale, isTrue);
    controller.refreshApproval();
    expect(controller.tasks, isEmpty);
  });

  test(
    'invalid selection and approval reject before file reads or transport',
    () async {
      for (final selection in <List<String>>[
        [],
        ['lib/no.dart'],
        ['lib/main.dart', 'lib/main.dart'],
      ]) {
        await controller.request('Tanalyze', selection);
        expect(controller.error, contains('Select'));
      }
      await PlanApprovalStore(records)
          .save(project, ConversationStore(records).load(project.id), false);
      await controller.request('Tanalyze', ['lib/main.dart']);
      expect(reads, 0);
      expect(provider.prompt, isNull);
    },
  );

  test('approval withdrawal during capture prevents inference', () async {
    controller.dispose();
    final capture = Completer<Map<String, String>>();
    controller = create(capture: capture);
    final pending = controller.request('Tanalyze', ['lib/main.dart']);
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    capture.complete(originals);
    await pending;
    expect(controller.error, contains('failed'));
    expect(provider.prompt, isNull);
    expect(controller.proposal, isNull);
  });

  test('cancel and dispose during capture suppress late inference and notifications', () async {
    for (final dispose in [false, true]) {
      if (!controller.isDisposed) controller.dispose();
      final capture = Completer<Map<String, String>>();
      controller = create(capture: capture);
      var updates = 0;
      controller.addListener(() => updates++);
      final pending = controller.request('Tanalyze', ['lib/main.dart']);
      if (dispose) {
        controller.dispose();
      } else {
        await controller.cancel();
      }
      final before = updates;
      capture.complete(originals);
      await pending;
      expect(provider.prompt, isNull);
      expect(controller.proposal, isNull);
      if (dispose) expect(updates, before);
    }
  });

  test('cancel during inference suppresses completed response', () async {
    final pending = controller.request('Tanalyze', ['lib/main.dart']);
    await tick();
    await controller.cancel();
    provider.stream.add(response());
    await provider.stream.close();
    await pending;
    expect(controller.busy, isFalse);
    expect(controller.proposal, isNull);
    expect(controller.status, contains('cancelled'));
    expect(provider.cancellations, greaterThan(0));
  });

  test('model failure ends busy state and preserves saved outcome', () async {
    final saved = controller.generated;
    final pending = controller.request('Tanalyze', ['lib/main.dart']);
    await tick();
    provider.stream.addError(StateError('offline'));
    await provider.stream.close();
    await pending;
    expect(controller.busy, isFalse);
    expect(controller.error, contains('offline'));
    expect(controller.generated, same(saved));
    expect(controller.proposal, isNull);
  });

  testWidgets(
    'narrow enlarged-text review shows full originals and replacement',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SourceReviewScreen(controller: controller),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Tanalyze: analyze'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Tanalyze: analyze'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('lib/main.dart'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('lib/main.dart'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Request source proposal'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Request source proposal'));
      await tester.pump();
      await tester.pump();
      expect(provider.prompt, isNotNull);
      provider.stream.add(response());
      unawaited(provider.stream.close());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Original (full file)'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(originals.values.single), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('void main() { print("Hi"); }'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('void main() { print("Hi"); }'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
