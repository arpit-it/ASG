import 'dart:async';
import 'dart:convert';

import 'package:asg/models/app_definition.dart';

import 'package:asg/controllers/portable_archive_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/archive_file_service.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/portable_archive_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/views/portable_archive_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Records implements ConditionalRecordStorage {
  final values = <String, String>{};
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
    if (fail || expected.entries.any((e) => values[e.key] != e.value)) {
      throw StateError('Refused');
    }
    authorize();
    values.addAll(updates);
  }
}

class Files extends ArchiveFileService {
  String? selected, written;
  Stream<List<int>>? stream;
  Completer<String?>? pending;
  bool cancelled = false, fail = false;
  @override
  bool get canExport => true;
  @override
  Future<String?> pickImport() async {
    if (fail) {
      throw StateError('File error');
    }
    if (stream != null) {
      return ArchiveFileService.readBounded(
        stream!,
        timeout: const Duration(milliseconds: 100),
      );
    }
    return pending == null ? selected : await pending!.future;
  }

  @override
  Future<bool> export(String encoded) async {
    if (fail) {
      throw StateError('Write error');
    }
    if (cancelled) return false;
    written = encoded;
    return true;
  }
}

String archive() => PortableProjectArchive(
  prototype: PortablePrototype(
    revision: 12,
    definition: const AppDefinition(
      title: 'Saved prototype',
      theme: 'green',
      elements: [
        AppElement(
          id: 'heading',
          kind: ElementKind.heading,
          label: 'Saved heading',
        ),
      ],
    ),
  ),
  requirements: RequirementsBoard(revision: 3),
  revisions: [
    PortableRevisionSummary(
      recordedAt: null,
      outcome: 'failed',
      passedChecks: 0,
      totalChecks: 1,
      requirementsRevision: 3,
      prototypeRevision: 12,
    ),
  ],
  decision: PortablePlanDecision(
    content: "Historical only",
    approved: false,
    recordedAt: DateTime.utc(2026),
  ),
  messages: const [ChatMessage(role: 'user', content: 'Exact private text 😀')],
).encode();
void main() {
  test(
    'damaged saved prototype blocks export and malformed import writes nothing',
    () async {
      final records = Records();
      records.values['studio.application.v1.p'] =
          '{"definition":null,"messages":[],"revision":1}';
      final c = PortableArchiveController(
        'p',
        records,
        files: Files()
          ..selected = archive().replaceFirst('"revision":12', '"revision":0'),
      );
      addTearDown(c.dispose);
      await c.prepareExport();
      expect(c.error, isNotNull);
      expect(c.exportPreview, isNull);
      final before = Map.of(records.values);
      await c.pickImport();
      expect(c.error, isNotNull);
      expect(c.importPreview, isNull);
      await c.restoreWorkspace('new', 'New');
      expect(records.values, before);
    },
  );
  test('bounded bytes reject overflow and invalid UTF-8', () async {
    final encoded = archive();
    final bytes = utf8.encode(encoded);
    expect(
      await ArchiveFileService.readBounded(
        Stream.fromIterable([bytes.sublist(0, 5), bytes.sublist(5)]),
      ),
      encoded,
    );
    await expectLater(
      ArchiveFileService.readBounded(Stream.value([0xff])),
      throwsFormatException,
    );
    await expectLater(
      ArchiveFileService.readBounded(
        Stream.fromIterable([
          List.filled(PortableProjectArchive.maxBytes, 32),
          [32],
        ]),
      ),
      throwsFormatException,
    );
  });
  test(
    'stalled import times out despite stalled cleanup; retry is safe',
    () async {
      var cancelled = false;
      final cleanup = Completer<void>();
      final source = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
          return cleanup.future;
        },
      );
      final records = Records()..values['existing'] = 'retained';
      final files = Files()..stream = source.stream;
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      final importing = c.pickImport();
      source.add(utf8.encode('{"format":'));
      await Future<void>.delayed(Duration.zero);
      expect(c.busy, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await importing;
      expect(cancelled, isTrue);
      expect(c.busy, isFalse);
      expect(c.importPreview, isNull);
      expect(c.error, contains('timed out'));
      expect(records.values, {'existing': 'retained'});
      files.stream = null;
      files.selected = archive();
      await c.pickImport();
      expect(c.error, isNull);
      expect(c.importPreview!.encode(), archive());
      expect(records.values, {'existing': 'retained'});
      cleanup.complete();
      await source.close();
    },
  );

  test(
    'whole-read deadline refuses continuously arriving partial bytes',
    () async {
      var cancelled = false;
      final source = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final reading = ArchiveFileService.readBounded(
        source.stream,
        timeout: const Duration(milliseconds: 100),
      );
      final failure = expectLater(reading, throwsA(isA<TimeoutException>()));
      for (var i = 0; i < 4; i++) {
        source.add([32]);
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      await failure;
      expect(cancelled, isTrue);
      await source.close();
    },
  );

  test('provider and byte-limit errors cancel subscriptions', () async {
    for (final oversized in [false, true]) {
      var cancelled = false;
      final source = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      final reading = ArchiveFileService.readBounded(source.stream);
      final failure = expectLater(
        reading,
        oversized ? throwsFormatException : throwsStateError,
      );
      if (oversized) {
        source.add(List.filled(PortableProjectArchive.maxBytes + 1, 32));
      } else {
        source.addError(StateError('Unavailable provider'));
      }
      await failure;
      expect(cancelled, isTrue);
      await source.close();
    }
    await expectLater(
      ArchiveFileService.readBounded(
        const Stream.empty(),
        timeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  test('export snapshots saved text and strips consent; cancel/error preserve retry', () async {
    final records = Records();
    final files = Files();
    await ConversationStore(records).save('p', const [
      ChatMessage(
        role: 'assistant',
        content: 'Plan',
        planContext: 'private-context',
      ),
    ]);
    final c = PortableArchiveController('p', records, files: files);
    addTearDown(c.dispose);
    await c.prepareExport();
    await ConversationStore(records)
        .save('p', const [ChatMessage(role: 'user', content: 'Later')]);
    await c.exportFile();
    expect(files.written, contains('Plan'));
    expect(files.written, isNot(contains('Later')));
    expect(files.written, isNot(contains('private-context')));
    files.cancelled = true;
    await c.exportFile();
    expect(c.status, 'Export cancelled.');
    files.fail = true;
    await c.exportFile();
    expect(c.error, isNotNull);
    expect(c.exportPreview, isNotNull);
    records.values['studio.chat.v1.p'] = '{}';
    await c.prepareExport();
    expect(c.exportPreview, isNull);
    expect(c.error, isNotNull);
  });
  test(
    'import preview writes nothing, failure/collision retry never replaces',
    () async {
      final records = Records();
      final files = Files()..selected = archive();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      await c.pickImport();
      expect(records.values, isEmpty);
      records.fail = true;
      await c.saveCopy('copy');
      expect(c.error, isNotNull);
      expect(c.importPreview, isNotNull);
      expect(records.values, isEmpty);
      records.fail = false;
      await c.saveCopy('copy');
      expect(c.importPreview, isNull);
      expect(PortableArchiveStore(records).load('copy')!.encode(), archive());
      await c.pickImport();
      await c.saveCopy('copy');
      expect(c.error, isNotNull);
      expect(c.importPreview, isNotNull);
      expect(records.values.length, 1);
      await c.saveCopy('../bad');
      expect(records.values.length, 1);
      files.selected = '{}';
      await c.pickImport();
      expect(c.importPreview, isNull);
      expect(c.error, isNotNull);
      files.selected = null;
      await c.pickImport();
      expect(c.status, 'File selection cancelled.');
      files.fail = true;
      await c.pickImport();
      expect(c.importPreview, isNull);
      expect(records.values.length, 1);
    },
  );
  test(
    'busy exclusion and disposal during picker prevent publication',
    () async {
      final records = Records();
      final files = Files()..pending = Completer<String?>();
      final c = PortableArchiveController('p', records, files: files);
      var notifications = 0;
      c.addListener(() => notifications++);
      final picking = c.pickImport();
      await c.saveCopy('copy');
      await c.restoreWorkspace('new', 'Ignored');
      expect(c.busy, isTrue);
      c.dispose();
      final before = notifications;
      files.pending!.complete(archive());
      await picking;
      await c.saveCopy('after');
      await c.restoreWorkspace('after', 'Ignored');
      expect(records.values, isEmpty);
      expect(notifications, before);
    },
  );
  test('workspace commit failure retains preview for retry', () async {
    final records = Records()..fail = true;
    final c = PortableArchiveController(
      'p',
      records,
      files: Files()..selected = archive(),
    );
    addTearDown(c.dispose);
    await c.pickImport();
    await c.restoreWorkspace('new', 'Restored');
    expect(c.error, isNotNull);
    expect(c.importPreview, isNotNull);
    expect(records.values, isEmpty);
    records.fail = false;
    records.values['studio.projects.v1'] = '{}';
    await c.restoreWorkspace('new', 'Restored');
    expect(c.error, isNotNull);
    expect(records.values, {'studio.projects.v1': '{}'});
    records.values.clear();
    await c.restoreWorkspace('new', 'Restored');
    expect(c.importPreview, isNull);
    expect(c.status, contains('Open it from Projects'));
    expect(records.values['studio.projects.v1'], contains('Restored'));
    expect(records.values['studio.planApproval.v1.new'], isNull);
  });
  testWidgets('narrow large text preview saves only on explicit action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = Records();
    final c = PortableArchiveController(
      'p',
      records,
      files: Files()..selected = archive(),
    );
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
    final select = find.text('Select archive file (up to 1 MiB)');
    await tester.scrollUntilVisible(
      select,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(select);
    await tester.pumpAndSettle();
    expect(records.values, isEmpty);
    final prototype = find.text(
      'Saved prototype: Saved prototype · revision 12',
    );
    await tester.scrollUntilVisible(
      prototype,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(prototype, findsOneWidget);
    final revisionHistory = find.text(
      'Historical revision summaries only; artifacts and rollback are unavailable.',
    );
    await tester.scrollUntilVisible(
      revisionHistory,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(revisionHistory, findsOneWidget);
    final history = find.text(
      'Historical information only. This does not grant Build approval.',
    );
    await tester.scrollUntilVisible(
      history,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(history, findsOneWidget);
    expect(tester.takeException(), isNull);
    final id = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.labelText == 'New backup or project ID',
    );
    await tester.scrollUntilVisible(
      id,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(id, 'ui-copy');
    final save = find.text('Save separate data copy');
    await tester.scrollUntilVisible(
      save,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(PortableArchiveStore(records).load('ui-copy')!.encode(), archive());
    expect(find.textContaining('Data copy saved as ui-copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('narrow large text restores only on explicit action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = Records();
    final c = PortableArchiveController(
      'p',
      records,
      files: Files()..selected = archive(),
    );
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
    final select = find.text('Select archive file (up to 1 MiB)');
    await tester.scrollUntilVisible(
      select,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(select);
    await tester.pumpAndSettle();
    expect(records.values, isEmpty);
    final history = find.text(
      'Historical information only. This does not grant Build approval.',
    );
    await tester.scrollUntilVisible(
      history,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(history, findsOneWidget);
    expect(tester.takeException(), isNull);
    final id = find.byWidgetPredicate(
      (w) =>
          w is TextField &&
          w.decoration?.labelText == 'New backup or project ID',
    );
    await tester.scrollUntilVisible(
      id,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(id, 'ui-copy');
    final name = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'New project name',
    );
    await tester.scrollUntilVisible(
      name,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(name, 'Restored UI');
    final save = find.text('Restore records into new project');
    await tester.scrollUntilVisible(
      save,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(records.values['studio.projects.v1'], contains('Restored UI'));
    expect(
      records.values['studio.chat.v1.ui-copy'],
      contains('Exact private text'),
    );
    expect(records.values['studio.planApproval.v1.ui-copy'], isNull);
    expect(find.textContaining('Project "Restored UI" saved.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
