// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/chat_message.dart';
import 'package:asg/models/html/html_operation_plan.dart';
import 'package:asg/models/html/saved_html_starter.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/services/html/html_site_template.dart';
import 'package:asg/services/html/html_source_check_native.dart';
import 'package:asg/views/html_project_workspace.dart';
import 'package:flutter/material.dart';

import 'package:asg/controllers/html_preview_controller.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/html/html_plan_preview.dart';
import 'package:asg/services/html/html_preview.dart';
import 'package:asg/services/html/html_project_store.dart';
import 'package:asg/services/html/html_starter_runner.dart';
import 'package:asg/services/html/html_starter_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_plan_check_test.dart' as checks;
import 'html_plan_consent_test.dart' as consent;
import 'html_planning_test.dart' as html;

class RealHttp extends HttpOverrides {}

class Preview implements HtmlPreview {
  int starts = 0, stops = 0, opens = 0;
  bool failStop = false;
  void Function()? authorize;
  Completer<Uri>? pending;
  @override
  bool get supported => true;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
    void Function()? authorizeRead,
  }) async {
    starts++;
    authorize = authorizeRead;
    authorizeRead?.call();
    return pending == null
        ? Uri.parse('http://127.0.0.1:1234/token/')
        : await pending!.future;
  }

  @override
  Future<void> open() async {
    opens++;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('private cleanup');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual approved preview serves original files and refuses withdrawn consent', () async {
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
    final c = HtmlPreviewController(
      HtmlPlanPreview(
        project,
        records,
        HtmlStarterRunner(checker: NativeHtmlSourceChecker()),
      ),
    );
    final request = HtmlExportRequest(
      input: input,
      parent: dir.parent.path,
      folderName: dir.path.split("/").last,
    );
    addTearDown(c.dispose);
    await c.start(dir.path, request);
    expect(c.url, isNotNull);
    final client = HttpOverrides.runWithHttpOverrides(
      () => HttpClient(),
      RealHttp(),
    );
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(c.url!)).close();
    expect(response.statusCode, 200);
    expect(await utf8.decoder.bind(response).join(), contains('Site'));
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    for (final method in ['GET', 'HEAD']) {
      final denied = await (await client.openUrl(method, c.url!)).close();
      expect(denied.statusCode, 403);
      expect(await denied.fold<int>(0, (n, bytes) => n + bytes.length), 0);
    }
    await c.stop();
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), true);
    await c.start(dir.path, request);
    expect(c.url, isNotNull);
    await c.stop();
    await File('${dir.path}/index.html').writeAsString('edited');
    await c.start(dir.path, request);
    expect(c.url, isNull);
    expect(await File('${dir.path}/index.html').readAsString(), 'edited');
  }, skip: !Platform.isMacOS);
  testWidgets('320px 2x approved preview action and refusal reachable', (
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
    final button = find.text('Preview approved HTML Plan');
    await tester.scrollUntilVisible(
      button,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(button);
    await tester.pumpAndSettle();
    final refusal = find.textContaining('Preview could not start.');
    await tester.scrollUntilVisible(
      refusal,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(refusal, findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !Platform.isMacOS);
  for (final key in [
    'studio.projects.v1',
    HtmlStarterStore.key,
    'studio.chat.v1.html-plan',
    'studio.requirements.v1.html-plan',
    consent.approvalKey,
  ]) {
    test('changed $key between check and preview prevents dispatch', () async {
      final records = await checks.approved();
      final checker = checks.Checker();
      final preview = Preview();
      final service = HtmlPlanPreview(
        html.project,
        records,
        HtmlStarterRunner(checker: checker, preview: preview),
      );
      final starter = HtmlProjectStore(records).resolve(html.project);
      final pending = service.start(
        directory: starter.directory,
        input: starter.input,
      );
      records.values[key] = 'private corrupt input';
      expect(checker.authorize!, throwsA(anything));
      checker.pending.complete(checks.checked);
      await expectLater(pending, throwsA(anything));
      expect(preview.starts, 0);
      await service.stop();
    });
  }
  test('missing consent and mismatched input never check or preview', () async {
    final records = await consent.seed();
    final checker = checks.Checker();
    final preview = Preview();
    final service = HtmlPlanPreview(
      html.project,
      records,
      HtmlStarterRunner(checker: checker, preview: preview),
    );
    final starter = HtmlProjectStore(records).resolve(html.project);
    await expectLater(
      service.start(directory: starter.directory, input: starter.input),
      throwsStateError,
    );
    await PlanApprovalStore(records).save(
      html.project,
      ConversationStore(records).load(html.project.id),
      true,
    );
    await expectLater(
      service.start(
        directory: starter.directory,
        input: HtmlSiteInput(title: 'Other', description: 'Changed'),
      ),
      throwsStateError,
    );
    expect(checker.calls, 0);
    expect(preview.starts, 0);
  });
  for (final action in ['withdraw', 'replace', 'stop', 'dispose']) {
    test('$action revokes serving and browser authority', () async {
      final records = await checks.approved();
      final before = Map.of(records.values);
      final checker = checks.Checker()..pending.complete(checks.checked);
      final preview = Preview();
      final service = HtmlPlanPreview(
        html.project,
        records,
        HtmlStarterRunner(checker: checker, preview: preview),
      );
      final c = HtmlPreviewController(service);
      final starter = HtmlProjectStore(records).resolve(html.project);
      await c.start(
        starter.directory,
        HtmlExportRequest(
          input: starter.input,
          parent: '/tmp',
          folderName: 'site',
        ),
      );
      expect(c.url, isNotNull);
      expect(checker.calls, 1);
      expect(records.values, before);
      await c.open();
      expect(preview.opens, 1);
      if (action == 'withdraw') {
        await PlanApprovalStore(records).save(
          html.project,
          ConversationStore(records).load(html.project.id),
          false,
        );
      } else if (action == 'replace') {
        final value = jsonDecode(
          records.values[consent.approvalKey]!,
        ) as Map<String, dynamic>;
        value['recordedAt'] = '2030-01-01T00:00:00.000Z';
        records.values[consent.approvalKey] = jsonEncode(value);
      } else if (action == 'stop') {
        await c.stop();
      } else {
        c.dispose();
      }
      expect(preview.authorize!, throwsA(anything));
      await c.open();
      expect(preview.opens, 1);
      if (action != 'dispose') c.dispose();
    });
  }
  testWidgets(
    'deadline retains pending check ownership and permits retry only after settling',
    (tester) async {
      final records = await checks.approved();
      final checker = checks.Checker();
      final preview = Preview();
      final service = HtmlPlanPreview(
        html.project,
        records,
        HtmlStarterRunner(checker: checker, preview: preview),
      );
      final c = HtmlPreviewController(service);
      addTearDown(c.dispose);
      final starter = HtmlProjectStore(records).resolve(html.project);
      final request = HtmlExportRequest(
        input: starter.input,
        parent: '/tmp',
        folderName: 'site',
      );
      final pending = c.start(starter.directory, request);
      await tester.pump(const Duration(seconds: 11));
      expect(checker.authorize!, throwsStateError);
      await c.start(starter.directory, request);
      expect(checker.calls, 1);
      expect(c.busy, true);
      checker.pending.complete(checks.checked);
      await pending;
      expect(c.url, isNull);
      expect(preview.starts, 0);
      checker.pending = Completer()..complete(checks.checked);
      await c.start(starter.directory, request);
      expect(c.url, isNotNull);
    },
  );
  test(
    'late revocation cleanup failure blocks restart until explicit Stop retry',
    () async {
      final records = await checks.approved();
      final checker = checks.Checker()..pending.complete(checks.checked);
      final preview = Preview()..pending = Completer();
      final service = HtmlPlanPreview(
        html.project,
        records,
        HtmlStarterRunner(checker: checker, preview: preview),
      );
      final c = HtmlPreviewController(service);
      addTearDown(c.dispose);
      final starter = HtmlProjectStore(records).resolve(html.project);
      final request = HtmlExportRequest(
        input: starter.input,
        parent: '/tmp',
        folderName: 'site',
      );
      final pending = c.start(starter.directory, request);
      while (preview.starts == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      await c.stop();
      preview.failStop = true;
      preview.pending!.complete(Uri.parse('http://127.0.0.1:1234/token/'));
      await pending;
      expect(c.url, isNull);
      expect(c.cleanupFailed, true);
      expect(c.error, contains("cleanup failed"));
      expect(c.notice, isNull);
      await c.start(starter.directory, request);
      expect(preview.starts, 1);
      preview.failStop = false;
      await c.stop();
      expect(c.cleanupFailed, false);
    },
  );
}
