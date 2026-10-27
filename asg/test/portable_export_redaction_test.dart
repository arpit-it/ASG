import 'dart:convert';
import 'dart:async';

import 'package:asg/controllers/portable_archive_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/portable_export_redaction.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/views/portable_archive_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'portable_archive_controller_test.dart' as fixtures;

void main() {
  test('literal redaction preserves structure, links, history and source', () {
    final source = PortableProjectArchive.decode(fixtures.archive());
    final before = source.encode();
    final result = PortableExportRedaction.apply(source, 'private');
    expect(result.matches, 1);
    expect(
      result.archive.requirements.requirements.first.id,
      'PrivateRequirement',
    );
    expect(result.archive.requirements.tasks.first.id, 'PrivateTask');
    expect(result.archive.requirements.tasks.last.dependencies, [
      'PrivateTask',
    ]);
    expect(
      result.archive.prototype!.definition.elements.first.target,
      'private-target',
    );
    expect(source.encode(), before);
    expect(
      result.archive.revisions.first.toJson(),
      source.revisions.first.toJson(),
    );
    expect(result.archive.decision!.toJson(), source.decision!.toJson());
  });

  test('project intent redaction keeps type and platform validation', () {
    final source = PortableProjectArchive(
      requirements: RequirementsBoard(),
      messages: const [],
      project: PortableProjectIntent(
        description: 'private private',
        type: 'private app',
        platforms: ['private OS'],
      ),
    );
    final result = PortableExportRedaction.apply(source, 'private');
    expect(result.matches, 4);
    expect(result.archive.project!.description, '[redacted] [redacted]');
    expect(result.archive.project!.type, '[redacted] app');
    expect(result.archive.project!.platforms, ['[redacted] OS']);
    expect(source.project!.description, 'private private');
  });

  test('decoded quotes, escapes and repeated literal matches round trip', () {
    const private = 'private "quote"\\\n😀';
    final raw = jsonDecode(fixtures.archive()) as Map<String, dynamic>;
    raw['requirements']['requirements'][0]['title'] = private;
    raw['requirements']['requirements'][0]['acceptance'] = '$private $private';
    raw['requirements']['tasks'][0]['title'] = private;
    raw['prototype']['definition']['title'] = private;
    raw['prototype']['definition']['elements'][0]['label'] = private;
    raw['prototype']['definition']['elements'][0]['items'] = [private];
    raw['prototype']['definition']['elements'][0]['value'] = private;
    raw['prototype']['messages'][0]['content'] = private;
    raw['decision']['content'] = private;
    raw['messages'][0]['content'] = private;
    final source = PortableProjectArchive.decode(jsonEncode(raw));
    final result = PortableExportRedaction.apply(source, private);
    expect(result.matches, 11);
    expect(result.archive.encode(), isNot(contains('quote')));
    expect(result.archive.messages.single.content, '[redacted]');
    final restored = PortableProjectArchive.decode(result.archive.encode());
    expect(restored.encode(), result.archive.encode());
    expect(source.messages.single.content, private);
    expect(restored.decision!.approved, source.decision!.approved);
    expect(restored.prototype!.revision, 12);
  });

  test('invalid, absent and oversized replacements refuse atomically', () {
    final source = PortableProjectArchive.decode(fixtures.archive());
    for (final literal in ['', 'not present', 'PrivateTask']) {
      expect(
        () => PortableExportRedaction.apply(source, literal),
        throwsFormatException,
      );
    }
    final long = PortableProjectArchive(
      requirements: RequirementsBoard(
        revision: 1,
        requirements: [
          ProjectRequirement(
            id: 'R1',
            title: List.filled(200, 'a').join(),
            acceptance: 'OK',
          ),
        ],
      ),
      messages: const [],
    );
    final before = long.encode();
    expect(
      () => PortableExportRedaction.apply(long, 'a'),
      throwsFormatException,
    );
    expect(long.encode(), before);
  });

  test(
    'blocked project and saved copy can be redacted without source writes',
    () async {
      for (final copy in [false, true]) {
        final records = fixtures.Records();
        final files = fixtures.Files();
        final c = PortableArchiveController('p', records, files: files);
        addTearDown(c.dispose);
        final secret = PortableProjectArchive(
          requirements: RequirementsBoard(),
          messages: const [
            ChatMessage(
              role: 'user',
              content: 'password=fixture-a Bearer fixture-b personal note',
            ),
          ],
        );
        if (copy) {
          records.values['studio.archive.v1.copy'] = secret.encode();
        } else {
          records.values['studio.chat.v1.p'] = jsonEncode([
            {'role': 'user', 'content': secret.messages.single.content},
          ]);
        }
        final before = Map.of(records.values);
        Future<void> load() =>
            copy ? c.prepareCopyExport('copy') : c.prepareExport();
        await load();
        expect(c.exportPreview, isNull);
        expect(c.exportReviewContents, contains('fixture-a'));
        await c.exportFile();
        expect(files.written, isNull);
        await c.redactExport('password=fixture-a');
        expect(c.exportPreview, isNull);
        expect(c.exportReviewContents, isNot(contains('fixture-a')));
        expect(c.exportReviewContents, contains('fixture-b'));
        await c.redactExport('Bearer fixture-b');
        expect(c.error, isNull);
        await c.redactExport('personal note');
        final payload = c.exportReviewContents;
        expect(payload, c.exportContents);
        await c.exportFile();
        expect(files.written, payload);
        expect(records.values, before);
        files.selected = payload;
        await c.pickImport();
        await c.restoreWorkspace('restored', 'Redacted project');
        expect(
          records.values['studio.chat.v1.restored'],
          isNot(contains('fixture-')),
        );
        expect(records.values['studio.planApproval.v1.restored'], isNull);
        await c.pickImport();
        await c.saveCopy('redacted');
        expect(records.values['studio.archive.v1.redacted'], payload);
        expect(
          before.entries.every((e) => records.values[e.key] == e.value),
          isTrue,
        );
        await load();
        expect(c.exportReviewContents, contains('personal note'));
        expect(c.exportPreview, isNull);
      }
    },
  );

  test('redaction preserves preview on invalid edits and refuses busy/disposed work', () async {
    final records = fixtures.Records();
    final files = fixtures.Files()..selected = fixtures.archive();
    records.values['studio.archive.v1.copy'] = fixtures.archive();
    final c = PortableArchiveController('p', records, files: files);
    await c.prepareCopyExport('copy');
    final before = c.exportContents;
    await c.redactExport('');
    expect(c.error, isNotNull);
    expect(c.exportContents, before);
    files.cancelled = true;
    await c.exportFile();
    expect(files.written, isNull);
    expect(c.exportContents, before);
    files.pending = Completer<String?>();
    final pending = c.pickImport();
    await c.redactExport('Exact private text');
    expect(c.exportContents, before);
    c.dispose();
    files.pending!.complete(null);
    await pending;
    await c.redactExport('Exact private text');
    expect(c.exportContents, before);
  });

  testWidgets(
    'narrow export UI redacts blocked draft and exports reviewed payload',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = fixtures.Records();
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': 'password=fixture-secret'},
      ]);
      final before = Map.of(records.values);
      final files = fixtures.Files();
      final c = PortableArchiveController('p', records, files: files);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.8)),
            child: child!,
          ),
          home: PortableArchiveScreen(controller: c),
        ),
      );
      Future<void> reveal(Finder finder) async {
        await tester.scrollUntilVisible(
          finder,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      final load = find.text('Load saved records for export');
      await reveal(load);
      await tester.tap(load);
      await tester.pumpAndSettle();
      final input = find.widgetWithText(
        TextField,
        'Literal text to redact from export copy',
      );
      await reveal(input);
      await tester.enterText(input, 'password=fixture-secret');
      final redact = find.text('Redact export copy');
      await reveal(redact);
      await tester.tap(redact);
      await tester.pumpAndSettle();
      expect(c.exportContents, isNot(contains('fixture-secret')));
      expect(c.exportContents, contains('[redacted]'));
      final complete = find.text('Review complete archive JSON');
      await tester.scrollUntilVisible(
        complete,
        -180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(complete);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == c.exportContents,
        ),
        findsOneWidget,
      );
      await tester.tap(complete);
      await tester.pumpAndSettle();
      final export = find.text('Choose export file');
      await reveal(export);
      await tester.tap(export);
      await tester.pumpAndSettle();
      expect(files.written, c.exportContents);
      expect(records.values, before);
      expect(tester.takeException(), isNull);
    },
  );
}
