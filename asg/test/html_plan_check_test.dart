// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/html_plan_check_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/html/html_operation_plan.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/html_source_check.dart';
import 'package:asg/models/html/saved_html_starter.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/html/html_site_template.dart';
import 'package:asg/services/html/html_source_check.dart';
import 'package:asg/services/html/html_source_check_native.dart';
import 'package:asg/services/html/html_starter_runner.dart';
import 'package:asg/services/html/html_starter_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/html_project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_plan_consent_test.dart' as consent;
import 'html_planning_test.dart' as html;

const checked = HtmlSourceCheck(files: 5, bytes: 123);

class Checker implements HtmlSourceChecker {
  bool available = true;
  int calls = 0;
  void Function()? authorize;
  Completer<HtmlSourceCheck> pending = Completer();
  @override
  bool get supported => available;
  @override
  Future<HtmlSourceCheck> check({
    required String directory,
    required HtmlSiteInput input,
    required void Function() authorizeRead,
  }) {
    calls++;
    authorize = authorizeRead;
    authorizeRead();
    return pending.future;
  }
}

Future<consent.ConsentRecords> approved() async {
  final records = await consent.seed();
  await PlanApprovalStore(
    records,
  ).save(html.project, ConversationStore(records).load(html.project.id), true);
  return records;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('missing consent and unsupported host perform no reads', () async {
    final records = await consent.seed();
    final checker = Checker();
    final c = HtmlPlanCheckController(
      html.project,
      records,
      HtmlStarterRunner(checker: checker),
    );
    addTearDown(c.dispose);
    await c.check();
    expect(checker.calls, 0);
    await PlanApprovalStore(records).save(
      html.project,
      ConversationStore(records).load(html.project.id),
      true,
    );
    checker.available = false;
    await c.check();
    expect(checker.calls, 0);
    expect(c.message, contains('macOS'));
  });
  test('explicit check preserves records and suppresses overlap', () async {
    final records = await approved();
    final before = Map.of(records.values);
    final checker = Checker();
    final c = HtmlPlanCheckController(
      html.project,
      records,
      HtmlStarterRunner(checker: checker),
    );
    addTearDown(c.dispose);
    final pending = c.check();
    await c.check();
    expect(checker.calls, 1);
    checker.pending.complete(checked);
    await pending;
    expect(c.result, same(checked));
    expect(
      c.message,
      contains('Preview and full Plan execution remain unavailable'),
    );
    expect(records.values, before);
  });
  for (final key in [
    'studio.projects.v1',
    HtmlStarterStore.key,
    'studio.chat.v1.html-plan',
    'studio.requirements.v1.html-plan',
    consent.approvalKey,
  ]) {
    test('changed $key revokes every read and late evidence', () async {
      final records = await approved();
      final checker = Checker();
      final c = HtmlPlanCheckController(
        html.project,
        records,
        HtmlStarterRunner(checker: checker),
      );
      addTearDown(c.dispose);
      final pending = c.check();
      records.values[key] = 'PRIVATE /private/source';
      expect(checker.authorize!, throwsA(anything));
      final before = Map.of(records.values);
      checker.pending.complete(checked);
      await pending;
      expect(c.result, isNull);
      expect(c.message, isNot(contains('PRIVATE')));
      expect(records.values, before);
      await c.check();
      expect(checker.calls, 1);
    });
  }
  for (final action in ['stop', 'dispose', 'withdraw', 'replaceConsent']) {
    test('$action revokes pending authority', () async {
      final records = await approved();
      final checker = Checker();
      final c = HtmlPlanCheckController(
        html.project,
        records,
        HtmlStarterRunner(checker: checker),
      );
      final pending = c.check();
      if (action == 'stop') c.stop();
      if (action == 'dispose') c.dispose();
      if (action == 'withdraw') {
        await PlanApprovalStore(records).save(
          html.project,
          ConversationStore(records).load(html.project.id),
          false,
        );
      }
      if (action == 'replaceConsent') {
        final value = jsonDecode(
          records.values[consent.approvalKey]!,
        ) as Map<String, dynamic>;
        value['recordedAt'] = '2030-01-01T00:00:00.000Z';
        records.values[consent.approvalKey] = jsonEncode(value);
      }
      expect(checker.authorize!, throwsA(anything));
      checker.pending.complete(checked);
      await pending;
      expect(c.result, isNull);
      if (action != 'dispose') c.dispose();
    });
  }
  testWidgets('deadline blocks retry until pending IO settles', (tester) async {
    final records = await approved();
    final checker = Checker();
    final c = HtmlPlanCheckController(
      html.project,
      records,
      HtmlStarterRunner(checker: checker),
    );
    addTearDown(c.dispose);
    final pending = c.check();
    await tester.pump(const Duration(seconds: 10));
    expect(c.message, contains('deadline'));
    expect(checker.authorize!, throwsStateError);
    await c.check();
    expect(checker.calls, 1);
    expect(c.busy, true);
    checker.pending.complete(checked);
    await pending;
    expect(c.result, isNull);
    checker.pending = Completer();
    final retry = c.check();
    checker.pending.complete(checked);
    await retry;
    expect(c.result, same(checked));
  });
  test('failed check retains records and permits explicit retry', () async {
    final records = await approved();
    final checker = Checker();
    final c = HtmlPlanCheckController(
      html.project,
      records,
      HtmlStarterRunner(checker: checker),
    );
    addTearDown(c.dispose);
    final before = Map.of(records.values);
    final pending = c.check();
    checker.pending.completeError(StateError('PRIVATE /private/source'));
    await pending;
    expect(c.message, isNot(contains('PRIVATE')));
    checker.pending = Completer();
    final retry = c.check();
    checker.pending.complete(checked);
    await retry;
    expect(c.result, same(checked));
    expect(records.values, before);
  });
  test('actual approved native source check rejects edited file', () async {
    final records = await consent.seed();
    final temporary = await Directory.systemTemp.createTemp(
      'asg-approved-html-',
    );
    final dir = Directory(await temporary.resolveSymbolicLinks());
    addTearDown(() => dir.delete(recursive: true));
    final project = StudioProject(
      id: html.project.id,
      name: 'Site',
      description: 'Local',
      type: 'HTML',
      platforms: ['Web'],
      location: dir.path,
    );
    final input = HtmlSiteInput(title: 'Site', description: 'Original');
    await StudioStore(records).save([project]);
    records.values[HtmlStarterStore.key] = jsonEncode([
      SavedHtmlStarter(directory: dir.path, input: input).toJson(),
    ]);
    await ConversationStore(records).save(project.id, [
      ChatMessage(
        role: 'assistant',
        content: HtmlOperationPlan.contract,
        planContext: PlanApprovalStore(records).contextFor(project),
      ),
    ]);
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), true);
    for (final entry in HtmlSiteTemplate().generate(input).entries) {
      final file = File('${dir.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final c = HtmlPlanCheckController(
      project,
      records,
      HtmlStarterRunner(checker: NativeHtmlSourceChecker()),
    );
    addTearDown(c.dispose);
    await c.check();
    expect(c.result, isNotNull);
    await File('${dir.path}/index.html').writeAsString('edited');
    await c.check();
    expect(c.result, isNull);
    expect(await File('${dir.path}/index.html').readAsString(), 'edited');
  }, skip: !Platform.isMacOS);
  testWidgets('320px 2x workspace check action and refusal reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = await consent.seed();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: HtmlProjectWorkspace(project: html.project, records: records),
      ),
    );
    final button = find.text('Check approved HTML sources');
    await tester.scrollUntilVisible(
      button,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    final refusal = find.textContaining('Source check refused or failed.');
    await tester.scrollUntilVisible(
      refusal,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(refusal, findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isMacOS);
}
