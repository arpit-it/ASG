// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/html_source_review_controller.dart';
import 'package:asg/models/html/html_reference_report.dart';
import 'package:asg/models/html/html_source_draft.dart';
import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/services/html/html_source_draft_store.dart';
import 'package:asg/services/html/html_source_proposer.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/html_source_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'html_planning_test.dart' as html;
import 'html_source_proposer_test.dart' show Provider;
import 'html_source_review_test.dart' show response;

class Records implements ConditionalRecordStorage {
  final values = <String, String>{};
  Completer<void>? wait;
  bool fail = false;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    await wait?.future;
    authorize();
    if (fail || expected.entries.any((e) => values[e.key] != e.value)) {
      throw StateError('PRIVATE failure');
    }
    values.addAll(updates);
  }
}

Future<Records> records() async =>
    Records()..values.addAll((await html.seed()).values);
HtmlSourceReviewController controller(
  RecordStorage r, {
  Future<HtmlReferenceReport> Function(HtmlSourceProposal)? inspect,
  Duration deadline = const Duration(seconds: 90),
}) => HtmlSourceReviewController(
  project: html.project,
  records: r,
  inspectReferences: inspect,
  requestDeadline: deadline,
);
Future<HtmlSourceReviewController> ready(RecordStorage r) async {
  final p = Provider();
  final c = HtmlSourceReviewController(
    project: html.project,
    records: r,
    proposer: HtmlSourceProposer(createProvider: (_) => p),
    inspectReferences: (_) async => report(),
  );
  final request = c.request('Greeting');
  p.stream.add(response());
  await p.stream.close();
  await request;
  return c;
}

HtmlReferenceReport report() =>
    HtmlReferenceReport(elements: 1, references: 0, findings: 0, messages: []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('explicit save/reopen retains exact edits and provenance with fresh diagnostics', () async {
    final r = await records();
    final c = await ready(r);
    final files = {
      ...c.proposal!.files,
      'styles.css': 'main { color: purple; }',
    };
    await c.revise(c.proposal!, files);
    final before = Map.of(r.values);
    await c.saveDraft();
    expect(c.error, isNull);
    final saved = HtmlSourceDraftStore(r, html.project.id).load()!;
    expect(saved.proposal.files, files);
    expect(saved.locallyEdited, true);
    expect(saved.provenance.model, c.provenance!.model);
    expect(r.values.length, before.length + 1);
    for (final key in before.keys) {
      expect(r.values[key], before[key]);
    }
    final old = c.proposal!;
    c.dispose();
    var calls = 0;
    final restored = controller(
      r,
      inspect: (_) async {
        calls++;
        return report();
      },
    );
    addTearDown(restored.dispose);
    expect(restored.savedDraftAvailable, true);
    expect(restored.proposal, isNull);
    await restored.restoreDraft();
    expect(calls, 1);
    expect(restored.proposal!.files, files);
    expect(restored.locallyEdited, true);
    expect(identical(restored.proposal, old), false);
    expect(() => c.authorizeProposal(old), throwsStateError);
  });
  test(
    'real database reopen and damaged draft isolation retain original bytes',
    () async {
      final dir = await Directory.systemTemp.createTemp('asg-html-draft-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/records.db';
      var db = await databaseFactoryIo.openDatabase(path);
      var store = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      for (final e in (await records()).values.entries) {
        if (!e.key.startsWith('studio.application.')) {
          await store.setString(e.key, e.value);
        }
      }
      final c = await ready(store);
      await c.saveDraft();
      expect(c.error, isNull);
      final key = HtmlSourceDraftStore(store, html.project.id).key;
      final bytes = store.getString(key);
      c.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      store = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      final restored = controller(store);
      await restored.restoreDraft();
      expect(
        restored.proposal!.files,
        HtmlSourceProposal.decode(response()).files,
      );
      expect(store.getString(key), bytes);
      restored.dispose();
      await StoreRef<String, String>('records')
          .record(key)
          .put(db, 'PRIVATE corrupt');
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      store = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      final damaged = await ready(store);
      expect(damaged.savedDraftError, isNotNull);
      expect(damaged.savedDraftError, isNot(contains('PRIVATE')));
      await damaged.saveDraft();
      expect(damaged.proposal, isNotNull);
      expect(damaged.error, isNot(contains('PRIVATE')));
      expect(store.getString('studio.projects.v1'), isNotNull);
      expect(
        await StoreRef<String, String>('records').record(key).get(db),
        'PRIVATE corrupt',
      );
      damaged.dispose();
      await db.close();
    },
  );
  test(
    'changed context refuses restoration without erasing saved bytes',
    () async {
      final r = await records();
      final c = await ready(r);
      addTearDown(c.dispose);
      await c.saveDraft();
      final key = HtmlSourceDraftStore(r, html.project.id).key;
      final bytes = r.values[key];
      final old = c.proposal!;
      r.values['studio.chat.v1.${html.project.id}'] = 'changed';
      await c.restoreDraft();
      expect(c.proposal, isNull);
      expect(c.error, contains('context changed'));
      expect(r.values[key], bytes);
      expect(() => c.authorizeProposal(old), throwsStateError);
    },
  );
  test('failed and conflicting writes retain current source and previous saved bytes', () async {
    final r = await records();
    final c = await ready(r);
    addTearDown(c.dispose);
    await c.saveDraft();
    final key = HtmlSourceDraftStore(r, html.project.id).key;
    final bytes = r.values[key];
    final old = c.proposal!;
    r.fail = true;
    await c.saveDraft();
    expect(c.proposal, same(old));
    expect(c.error, isNot(contains('PRIVATE')));
    expect(r.values[key], bytes);
    r.fail = false;
    r.wait = Completer();
    final saving = c.saveDraft();
    await Future<void>.delayed(Duration.zero);
    final other = jsonDecode(bytes!) as Map<String, dynamic>;
    other['locallyEdited'] = true;
    r.values[key] = jsonEncode(other);
    final competing = r.values[key];
    r.wait!.complete();
    await saving;
    expect(c.proposal, same(old));
    expect(r.values[key], competing);
    expect(c.error, isNotNull);
    r.wait = null;
    await c.saveDraft();
    expect(c.error, isNull);
  });
  for (final action in ['stop', 'dispose', 'context', 'deadline', 'failure']) {
    test(
      'restore $action excludes overlap and suppresses late authority',
      () async {
        final r = await records();
        final initial = await ready(r);
        await initial.saveDraft();
        initial.dispose();
        final pending = Completer<HtmlReferenceReport>();
        var calls = 0;
        final c = controller(
          r,
          inspect: (_) {
            calls++;
            return pending.future;
          },
          deadline: action == 'deadline'
              ? const Duration(milliseconds: 1)
              : const Duration(seconds: 90),
        );
        final restoring = c.restoreDraft();
        expect(c.busy, true);
        await c.restoreDraft();
        await c.saveDraft();
        expect(calls, 1);
        if (action == 'stop') c.stop();
        if (action == 'dispose') c.dispose();
        if (action == 'context') {
          r.values['studio.chat.v1.${html.project.id}'] = 'changed';
        }
        if (action == 'deadline') {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        if (action == 'failure') {
          pending.completeError(StateError('PRIVATE'));
        } else {
          pending.complete(report());
        }
        await restoring;
        expect(c.proposal, isNull);
        expect(c.busy, false);
        expect(c.error, isNot(contains('PRIVATE')));
        expect(HtmlSourceDraftStore(r, html.project.id).load(), isNotNull);
        if (action != 'dispose') c.dispose();
      },
    );
  }
  for (final action in ['stop', 'dispose', 'context']) {
    test(
      'pending save $action revokes publication before durable commit',
      () async {
        final r = await records();
        final c = await ready(r);
        r.wait = Completer();
        final saving = c.saveDraft();
        await Future<void>.delayed(Duration.zero);
        await c.request('Overlap');
        await c.restoreDraft();
        if (action == 'stop') c.stop();
        if (action == 'dispose') c.dispose();
        if (action == 'context') {
          r.values['studio.chat.v1.${html.project.id}'] = 'changed';
        }
        r.wait!.complete();
        await saving;
        expect(HtmlSourceDraftStore(r, html.project.id).load(), isNull);
        expect(c.status, isNot(contains('Source draft saved locally.')));
        expect(c.busy, false);
        if (action != 'dispose') c.dispose();
      },
    );
  }

  test(
    'strict schema, identity and duplicates preserve malformed drafts',
    () async {
      final r = await records();
      final c = await ready(r);
      addTearDown(c.dispose);
      await c.saveDraft();
      final key = HtmlSourceDraftStore(r, html.project.id).key;
      final bytes = r.values[key]!;
      for (final e in <String, Object?>{
        'version': 2,
        'projectId': 'other',
        'contextDigest': 'bad',
        'locallyEdited': 1,
        'proposal': {},
      }.entries) {
        final map = jsonDecode(bytes) as Map<String, dynamic>;
        map[e.key] = e.value;
        final bad = jsonEncode(map);
        r.values[key] = bad;
        await c.saveDraft();
        expect(c.error, isNotNull);
        expect(r.values[key], bad);
      }
      expect(
        () => HtmlSourceDraft.decode(bytes.replaceFirst('{', '{"version":1,')),
        throwsFormatException,
      );
    },
  );
  testWidgets('320px 2x explicit save close reopen restore', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final r = await records();
    final c = await ready(r);
    Widget screen(HtmlSourceReviewController owner) => MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: const TextScaler.linear(2)),
        child: child!,
      ),
      home: HtmlSourceReviewScreen(controller: owner),
    );
    await tester.pumpWidget(screen(c));
    await tester.scrollUntilVisible(
      find.text('Save source draft locally'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Save source draft locally'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save source draft locally'));
    await tester.pumpAndSettle();
    expect(c.savedDraftAvailable, true);
    await tester.pumpWidget(const SizedBox());
    final restored = controller(r, inspect: (_) async => report());
    await tester.pumpWidget(screen(restored));
    expect(restored.proposal, isNull);
    await tester.scrollUntilVisible(
      find.text('Restore saved source draft'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Restore saved source draft'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore saved source draft'));
    await tester.pumpAndSettle();
    expect(restored.proposal, isNotNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
