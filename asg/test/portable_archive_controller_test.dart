import 'dart:async';
import 'dart:convert';

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
  Completer<String?>? pending;
  bool cancelled = false, fail = false;
  @override
  bool get canExport => true;
  @override
  Future<String?> pickImport() async {
    if (fail) {
      throw StateError('File error');
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
  requirements: RequirementsBoard(revision: 3),
  messages: const [ChatMessage(role: 'user', content: 'Exact private text 😀')],
).encode();
void main() {
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
      expect(c.busy, isTrue);
      c.dispose();
      final before = notifications;
      files.pending!.complete(archive());
      await picking;
      await c.saveCopy('after');
      expect(records.values, isEmpty);
      expect(notifications, before);
    },
  );
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
    final id = find.byType(TextField);
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
}
