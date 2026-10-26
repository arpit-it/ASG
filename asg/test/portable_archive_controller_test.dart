import 'dart:async';
import 'dart:convert';

import 'package:asg/models/app_definition.dart';
import 'package:asg/models/source_generation.dart';

import 'package:asg/controllers/portable_archive_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/archive_file_service.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/portable_archive_store.dart';
import 'package:asg/services/portable_workspace_restore.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/views/portable_archive_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Records implements ConditionalRecordStorage {
  final values = <String, String>{};
  bool fail = false;
  void Function()? beforeCommit;
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
    beforeCommit?.call();
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
    messages: const [
      ChatMessage(role: 'user', content: 'Change the prototype 😀'),
    ],
    definition: const AppDefinition(
      title: 'Saved prototype',
      theme: 'green',
      elements: [
        AppElement(
          id: 'heading',
          kind: ElementKind.heading,
          label: 'Saved heading',
          target: 'private-target',
        ),
      ],
    ),
  ),
  requirements: RequirementsBoard(
    revision: 3,
    requirements: const [
      ProjectRequirement(
        id: 'PrivateRequirement',
        title: 'Title',
        acceptance: 'Accept',
      ),
    ],
    tasks: [
      DevelopmentTask(
        id: 'PrivateTask',
        requirementId: 'PrivateRequirement',
        title: 'Task',
      ),
      DevelopmentTask(
        id: 'Dependent',
        requirementId: 'PrivateRequirement',
        title: 'Depends',
        dependencies: ['PrivateTask'],
      ),
    ],
  ),
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
    'unsafe requirements revision refuses export and restore without writes',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      final raw = jsonDecode(archive()) as Map<String, dynamic>;
      raw['requirements']['revision'] = 9007199254740992;
      final unsafe = jsonEncode(raw);
      records.values['studio.requirements.v1.p'] = jsonEncode(
        raw['requirements'],
      );
      records.values['studio.archive.v1.unsafe'] = unsafe;
      final before = Map.of(records.values);
      for (final prepare in [
        c.prepareExport,
        () => c.prepareCopyExport('unsafe'),
      ]) {
        // Establish a valid prior preview before each rejected replacement.
        records.values['studio.archive.v1.clean'] = archive();
        await c.prepareCopyExport('clean');
        expect(c.exportContents, isNotNull);
        await prepare();
        expect(c.error, isNotNull);
        expect(c.error, isNot(contains('PrivateRequirement')));
        expect(c.exportContents, isNull);
        await c.exportFile();
        expect(files.written, isNull);
      }
      records.values.remove('studio.archive.v1.clean');
      files.selected = unsafe;
      await c.pickImport();
      expect(c.importContents, isNull);
      await c.saveCopy('new-copy');
      await c.restoreWorkspace('new-project', 'Restored');
      expect(records.values, before);
      await expectLater(
        PortableArchiveStore(records).restoreCopy('new-copy', unsafe),
        throwsFormatException,
      );
      await expectLater(
        PortableWorkspaceRestore(records)
            .restore(id: 'new-project', name: 'Restored', encoded: unsafe),
        throwsFormatException,
      );
      expect(records.values, before);
      raw['requirements']['revision'] = 9007199254740991;
      records.values['studio.requirements.v1.p'] = jsonEncode(
        raw['requirements'],
      );
      await c.prepareExport();
      expect(c.error, isNull);
      expect(c.exportPreview!.requirements.revision, 9007199254740991);
      await c.exportFile();
      expect(files.written, isNotNull);
      files.selected = jsonEncode(raw);
      await c.pickImport();
      await c.restoreWorkspace('new-project', 'Restored');
      expect(c.error, isNull);
      expect(
        jsonDecode(
          records.values['studio.requirements.v1.new-project']!,
        )['revision'],
        9007199254740991,
      );
    },
  );

  test(
    'saved copy short Bearer refusal preserves records and permits retry',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      final store = PortableArchiveStore(records);
      await store.restoreCopy('clean', archive());
      await store.restoreCopy(
        'short',
        PortableProjectArchive(
          requirements: RequirementsBoard(),
          messages: const [ChatMessage(role: 'user', content: 'Bearer x')],
        ).encode(),
      );
      final before = Map.of(records.values);
      await c.prepareCopyExport('clean');
      expect(c.exportPreview, isNotNull);
      await c.prepareCopyExport('short');
      expect(c.error, startsWith('Export blocked:'));
      expect(c.error, isNot(contains('Bearer x')));
      expect(c.exportContents, isNull);
      await c.exportFile();
      expect(files.written, isNull);
      expect(records.values, before);
      await c.prepareCopyExport('clean');
      await c.exportFile();
      expect(c.error, isNull);
      expect(files.written, archive());
      expect(records.values, before);
    },
  );

  test(
    'short Bearer export refuses without writes and clean retry succeeds',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      for (final text in [
        'Authorization: Bearer x',
        'bEaReR\tx=',
        'Bearer +/==',
      ]) {
        records.values.clear();
        await c.prepareExport();
        expect(c.exportPreview, isNotNull);
        records.values['studio.chat.v1.p'] = jsonEncode([
          {'role': 'user', 'content': text},
        ]);
        final before = Map.of(records.values);
        files.written = null;
        await c.prepareExport();
        expect(c.error, startsWith('Export blocked:'));
        expect(c.error, isNot(contains(text)));
        expect(c.exportPreview, isNull);
        expect(c.exportContents, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        records.values.clear();
        await c.prepareExport();
        await c.exportFile();
        expect(c.error, isNull);
        expect(files.written, c.exportContents);
      }
    },
  );

  test(
    'HTTP user-info export refuses saved records and copies, then retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      final store = PortableArchiveStore(records);
      await store.restoreCopy('clean', archive());
      for (final text in [
        'https://fixture-token@example.test/repository',
        'HTTP://fixture-token:@example.test',
        'https://%66ixture-token@example.test',
      ]) {
        records.values['studio.chat.v1.p'] = jsonEncode([
          {'role': 'user', 'content': text},
        ]);
        records.values['studio.archive.v1.sensitive'] = PortableProjectArchive(
          requirements: RequirementsBoard(),
          messages: [ChatMessage(role: 'user', content: text)],
        ).encode();
        final before = Map.of(records.values);
        for (final prepare in [
          c.prepareExport,
          () => c.prepareCopyExport('sensitive'),
        ]) {
          await c.prepareCopyExport('clean');
          expect(c.exportPreview, isNotNull);
          files.written = null;
          await prepare();
          expect(c.error, startsWith('Export blocked:'));
          expect(c.error, isNot(contains('fixture-token')));
          expect(c.exportContents, isNull);
          await c.exportFile();
          expect(files.written, isNull);
          expect(records.values, before);
          await c.prepareCopyExport('clean');
          await c.exportFile();
          expect(c.error, isNull);
          expect(files.written, archive());
          expect(records.values, before);
        }
      }
    },
  );

  test(
    'PuTTY private key export refuses saved records and copies, then retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      final store = PortableArchiveStore(records);
      await store.restoreCopy('clean', archive());
      for (final text in [
        'PuTTY-User-Key-File-2: ssh-rsa\nEncryption: none\nPrivate-Lines: 1\nZml4dHVyZQ==',
        'PuTTY-User-Key-File-3: ssh-ed25519\r\nEncryption: aes256-cbc\r\nPrivate-Lines: 1\r\nZml4dHVyZQ==',
        'Saved key: PuTTY-User-Key-File-3: ecdsa-sha2-nistp256',
        'PuTTY%2DUser%2DKey%2DFile%2D2%3A%20ssh-rsa',
      ]) {
        records.values['studio.chat.v1.p'] = jsonEncode([
          {'role': 'user', 'content': text},
        ]);
        records.values['studio.archive.v1.sensitive'] = PortableProjectArchive(
          requirements: RequirementsBoard(),
          messages: [ChatMessage(role: 'user', content: text)],
        ).encode();
        final before = Map.of(records.values);
        for (final prepare in [
          c.prepareExport,
          () => c.prepareCopyExport('sensitive'),
        ]) {
          await c.prepareCopyExport('clean');
          expect(c.exportPreview, isNotNull);
          files.written = null;
          await prepare();
          expect(c.error, startsWith('Export blocked:'));
          expect(c.error, isNot(contains('PuTTY')));
          expect(c.exportContents, isNull);
          await c.exportFile();
          expect(files.written, isNull);
          expect(records.values, before);
          await c.prepareCopyExport('clean');
          await c.exportFile();
          expect(c.error, isNull);
          expect(files.written, archive());
          expect(records.values, before);
        }
      }
    },
  );

  test(
    'OpenPGP private key export refuses saved records and copies, then retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      final store = PortableArchiveStore(records);
      await store.restoreCopy('clean', archive());
      for (final text in [
        '-----BEGIN PGP PRIVATE KEY BLOCK-----',
        '-----BEGIN PGP PRIVATE KEY BLOCK-----\r\n\r\nZml4dHVyZQ==\r\n-----END PGP PRIVATE KEY BLOCK-----',
        'Saved key: -----BEGIN PGP PRIVATE KEY BLOCK-----\nfixture',
        '%2D%2D%2D%2D%2DBEGIN%20PGP%20PRIVATE%20KEY%20BLOCK%2D%2D%2D%2D%2D',
      ]) {
        records.values['studio.chat.v1.p'] = jsonEncode([
          {'role': 'user', 'content': text},
        ]);
        records.values['studio.archive.v1.sensitive'] = PortableProjectArchive(
          requirements: RequirementsBoard(),
          messages: [ChatMessage(role: 'user', content: text)],
        ).encode();
        final before = Map.of(records.values);
        for (final prepare in [
          c.prepareExport,
          () => c.prepareCopyExport('sensitive'),
        ]) {
          await c.prepareCopyExport('clean');
          expect(c.exportPreview, isNotNull);
          files.written = null;
          await prepare();
          expect(c.error, startsWith('Export blocked:'));
          expect(c.error, isNot(contains('PGP')));
          expect(c.exportContents, isNull);
          await c.exportFile();
          expect(files.written, isNull);
          expect(records.values, before);
          await c.prepareCopyExport('clean');
          await c.exportFile();
          expect(c.error, isNull);
          expect(files.written, archive());
          expect(records.values, before);
        }
      }
    },
  );

  test('SSH2 private key export refuses saved records and copies, then retries', () async {
    final records = Records();
    final files = Files();
    final c = PortableArchiveController('p', records, files: files);
    addTearDown(c.dispose);
    final store = PortableArchiveStore(records);
    await store.restoreCopy('clean', archive());
    for (final text in [
      '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----',
      '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\r\n\r\nZml4dHVyZQ==\r\n---- END SSH2 ENCRYPTED PRIVATE KEY ----',
      'Saved key: ---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nfixture',
      '%2D%2D%2D%2D%20BEGIN%20SSH2%20ENCRYPTED%20PRIVATE%20KEY%20%2D%2D%2D%2D',
    ]) {
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': text},
      ]);
      records.values['studio.archive.v1.sensitive'] = PortableProjectArchive(
        requirements: RequirementsBoard(),
        messages: [ChatMessage(role: 'user', content: text)],
      ).encode();
      final before = Map.of(records.values);
      for (final prepare in [
        c.prepareExport,
        () => c.prepareCopyExport('sensitive'),
      ]) {
        await c.prepareCopyExport('clean');
        expect(c.exportPreview, isNotNull);
        files.written = null;
        await prepare();
        expect(c.error, startsWith('Export blocked:'));
        expect(c.error, isNot(contains('SSH2')));
        expect(c.exportContents, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        await c.prepareCopyExport('clean');
        await c.exportFile();
        expect(c.error, isNull);
        expect(files.written, archive());
        expect(records.values, before);
      }
    }
  });

  test(
    'XML credential export refuses saved records and copies, then retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      final store = PortableArchiveStore(records);
      await store.restoreCopy('clean', archive());
      for (final text in [
        '<password><![CDATA[fixture-value]]></password>',
        '<cfg:token><value>fixture-value</value></cfg:token>',
        '<password><!--comment-->fixture-value</password>',
        Uri.encodeComponent('<password><![CDATA[fixture-value]]></password>'),
        '<cfg:password>fixture-value</cfg:password>',
        '<password type="text">fixture-value</password>',
        '<cfg:API_KEY hint="a>b">fixture-value</cfg:API_KEY>',
        "<cfg:token note='a>b'>fixture-value</cfg:token>",
        Uri.encodeComponent(
          '<cfg:password type="text">fixture-value</cfg:password>',
        ),
        '<password>fixture-value</password>',
        '<API_KEY>fixture-value</API_KEY>',
        '<client-secret>\r\nfixture-value\r\n</client-secret>',
        'Saved config: <token >fixture-value</token>',
        '%3Cpassword%3Efixture-value%3C%2Fpassword%3E',
      ]) {
        records.values['studio.chat.v1.p'] = jsonEncode([
          {'role': 'user', 'content': text},
        ]);
        records.values['studio.archive.v1.sensitive'] = PortableProjectArchive(
          requirements: RequirementsBoard(),
          messages: [ChatMessage(role: 'user', content: text)],
        ).encode();
        final before = Map.of(records.values);
        for (final prepare in [
          c.prepareExport,
          () => c.prepareCopyExport('sensitive'),
        ]) {
          await c.prepareCopyExport('clean');
          expect(c.exportPreview, isNotNull);
          files.written = null;
          await prepare();
          expect(c.error, startsWith('Export blocked:'));
          expect(c.error, isNot(contains('fixture-value')));
          expect(c.exportContents, isNull);
          await c.exportFile();
          expect(files.written, isNull);
          expect(records.values, before);
          await c.prepareCopyExport('clean');
          await c.exportFile();
          expect(c.error, isNull);
          expect(files.written, archive());
          expect(records.values, before);
        }
      }
    },
  );

  test('percent-encoded credential export refuses saved records and copies, then retries', () async {
    final records = Records();
    final files = Files();
    final c = PortableArchiveController('p', records, files: files);
    addTearDown(c.dispose);
    final store = PortableArchiveStore(records);
    await store.restoreCopy('clean', archive());
    for (final text in [
      'https://example.test?api%5Fkey=fixture-value',
      '%41uthorization%3A%20Bearer%20fixture-value',
      'https%3A%2F%2Ffixture-token%40example.test',
    ]) {
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': text},
      ]);
      records.values['studio.archive.v1.sensitive'] = PortableProjectArchive(
        requirements: RequirementsBoard(),
        messages: [ChatMessage(role: 'user', content: text)],
      ).encode();
      final before = Map.of(records.values);
      for (final prepare in [
        c.prepareExport,
        () => c.prepareCopyExport('sensitive'),
      ]) {
        await c.prepareCopyExport('clean');
        expect(c.exportPreview, isNotNull);
        files.written = null;
        await prepare();
        expect(c.error, startsWith('Export blocked:'));
        expect(c.error, isNot(contains('fixture-token')));
        expect(c.exportContents, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        await c.prepareCopyExport('clean');
        await c.exportFile();
        expect(c.error, isNull);
        expect(files.written, archive());
        expect(records.values, before);
      }
    }
  });

  test(
    'unknown saved build history fields refuse export and allow retry',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      const key = 'studio.generation.v1.p';
      final project = GeneratedProject(
        directory: '/private/source',
        sdk: '/private/sdk',
        python: '/private/python',
        sources: {'lib/main.dart': 'a' * 64},
        phase: SourceGenerationPhase.failed,
      ).toJson();
      final entry = <String, Object?>{
        'recordedAt': '2026-10-26T17:00:00.000Z',
        'project': project,
      };
      final supported = <String, Object?>{
        ...project,
        'buildHistoryVersion': 1,
        'buildHistory': [entry],
      };
      for (final extra in <Object?>[
        'private-future-value',
        {'nested': 1},
        null,
      ]) {
        for (final location in ['current', 'entry', 'project']) {
          records.values[key] = jsonEncode(supported);
          await c.prepareExport();
          expect(c.exportPreview, isNotNull);
          records.values[key] = jsonEncode({
            ...supported,
            if (location == 'current') 'futureField': extra,
            'buildHistory': [
              {
                ...entry,
                if (location == 'entry') 'futureField': extra,
                'project': {
                  ...project,
                  if (location == 'project') 'futureField': extra,
                },
              },
            ],
          });
          final before = Map.of(records.values);
          files.written = null;
          await c.prepareExport();
          expect(c.error, isNotNull, reason: location);
          expect(c.error, isNot(contains('private-future-value')));
          expect(c.exportPreview, isNull);
          await c.exportFile();
          expect(files.written, isNull);
          expect(records.values, before);
          records.values[key] = jsonEncode(supported);
          await c.prepareExport();
          await c.exportFile();
          expect(c.error, isNull);
          final revisions = PortableProjectArchive.decode(files.written!)
              .revisions;
          expect(revisions.single.recordedAt, DateTime.utc(2026, 10, 26, 17));
          expect(revisions.single.outcome, 'failed');
          expect(revisions.single.totalChecks, 0);
          expect(files.written, isNot(contains('/private/')));
        }
      }
      records.values[key] = jsonEncode(Map.of(project)..remove('limits'));
      await c.prepareExport();
      expect(c.error, isNull);
      expect(c.exportPreview!.revisions.single.recordedAt, isNull);
      records.values.clear();
      await c.prepareExport();
      expect(c.error, isNull);
      expect(c.exportPreview!.revisions, isEmpty);
    },
  );

  test(
    'saved copy export is exact, read-only and refuses stale or secret input',
    () async {
      final records = Records();
      final files = Files();
      final encoded = archive();
      await PortableArchiveStore(records).restoreCopy('copy', encoded);
      records.values[PortableArchiveStore.key('broken')] = '{broken';
      final secret = PortableProjectArchive(
        requirements: RequirementsBoard(),
        messages: const [
          ChatMessage(role: 'user', content: 'password=private123'),
        ],
      ).encode();
      await PortableArchiveStore(records).restoreCopy('secret', secret);
      final before = Map.of(records.values);
      final c = PortableArchiveController('unrelated', records, files: files);
      addTearDown(c.dispose);
      for (final id in ['missing', 'broken', '../copy', '', 'secret']) {
        await c.prepareCopyExport('copy');
        expect(c.exportContents, encoded);
        await c.prepareCopyExport(id);
        expect(c.exportContents, isNull);
        expect(c.error, isNotNull);
        expect(c.error, isNot(contains('private123')));
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
      }
      await c.prepareCopyExport('copy');
      records.values[PortableArchiveStore.key('copy')] = '{changed';
      files.cancelled = true;
      await c.exportFile();
      expect(c.status, 'Export cancelled.');
      files.cancelled = false;
      files.fail = true;
      await c.exportFile();
      expect(c.error, isNotNull);
      expect(c.exportContents, encoded);
      files.fail = false;
      await c.exportFile();
      expect(files.written, encoded);
      expect(records.values, {
        ...before,
        PortableArchiveStore.key('copy'): '{changed',
      });
      await c.prepareExport();
      expect(c.exportContents, isNot(encoded));
      expect(c.error, isNull);
    },
  );

  testWidgets(
    'saved copy export works at narrow enlarged text without restore',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      await PortableArchiveStore(records).restoreCopy('saved', archive());
      final before = Map.of(records.values);
      final files = Files();
      final c = PortableArchiveController('unused', records, files: files);
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
      Future<void> reveal(Finder finder, double delta) async {
        await tester.scrollUntilVisible(
          finder,
          delta,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      final id = find.widgetWithText(TextField, 'Saved data copy ID');
      await reveal(id, 300);
      await tester.enterText(id, 'saved');
      final load = find.text('Load saved copy for export');
      await reveal(load, 200);
      await tester.tap(load);
      await tester.pumpAndSettle();
      expect(c.exportContents, archive());
      expect(c.importPreview, isNull);
      expect(files.written, isNull);
      expect(records.values, before);
      final export = find.text('Choose export file');
      await reveal(export, -250);
      await tester.tap(export);
      await tester.pumpAndSettle();
      expect(files.written, archive());
      expect(records.values, before);
      expect(tester.takeException(), isNull);
    },
  );

  test('saved copies reopen read-only, clear stale previews and retry', () async {
    final records = Records();
    final encoded = archive();
    await PortableArchiveStore(records).restoreCopy('copy', encoded);
    records.values[PortableArchiveStore.key('broken')] = '{broken';
    final before = Map.of(records.values);
    final c = PortableArchiveController('p', records, files: Files());
    addTearDown(c.dispose);
    for (final invalid in ['missing', 'broken', '../copy', '']) {
      await c.loadCopy('copy');
      expect(c.importContents, encoded);
      expect(c.error, isNull);
      await c.loadCopy(invalid);
      expect(c.importPreview, isNull);
      expect(c.error, isNotNull);
      await c.restoreWorkspace('forbidden', 'Forbidden');
      expect(records.values, before);
    }
    await c.loadCopy('copy');
    // The validated preview remains a snapshot if the saved copy later changes.
    records.values[PortableArchiveStore.key('copy')] = '{damaged later';
    expect(c.importContents, encoded);
    await c.restoreWorkspace('new', 'Restored');
    expect(c.error, isNull);
    expect(c.importPreview, isNull);
    expect(records.values['studio.planApproval.v1.new'], isNull);
    expect(records.values['studio.generation.v1.new'], isNull);
    final restored = PortableArchiveController('new', records, files: Files());
    addTearDown(restored.dispose);
    await restored.prepareExport();
    expect(restored.exportContents, encoded);
  });

  testWidgets(
    'saved copy can be reviewed and restored at narrow enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      await PortableArchiveStore(records).restoreCopy('saved', archive());
      final before = Map.of(records.values);
      final c = PortableArchiveController('p', records, files: Files());
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
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      final savedId = find.widgetWithText(TextField, 'Saved data copy ID');
      await reveal(savedId);
      await tester.enterText(savedId, 'saved');
      final load = find.text('Load saved data copy');
      await reveal(load);
      await tester.tap(load);
      await tester.pumpAndSettle();
      expect(c.importContents, archive());
      expect(records.values, before);
      final id = find.widgetWithText(TextField, 'New backup or project ID');
      await reveal(id);
      await tester.enterText(id, 'new');
      final name = find.widgetWithText(TextField, 'New project name');
      await reveal(name);
      await tester.enterText(name, 'Reopened');
      final restore = find.text('Restore records into new project');
      await reveal(restore);
      await tester.tap(restore);
      await tester.pumpAndSettle();
      expect(c.error, isNull);
      expect(records.values['studio.projects.v1'], contains('Reopened'));
      expect(records.values['studio.planApproval.v1.new'], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'credential export refusal clears stale preview and permits clean retry',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      await c.prepareExport();
      expect(c.exportPreview, isNotNull);
      final clean = archive();
      final paths = <List<Object>>[
        ['messages', 0, 'content'],
        ['prototype', 'messages', 0, 'content'],
        ['prototype', 'definition', 'title'],
        ['prototype', 'definition', 'elements', 0, 'target'],
        ['requirements', 'requirements', 0, 'acceptance'],
        ['requirements', 'tasks', 0, 'title'],
        ['decision', 'content'],
      ];
      for (final path in paths) {
        final json = jsonDecode(clean) as Map<String, dynamic>;
        dynamic row = json;
        for (final key in path.take(path.length - 1)) {
          row = row[key];
        }
        row[path.last] = 'password: private-fixture-value';
        // Restored historical data uses the same production source namespaces.
        records.values
          ..clear()
          ..['studio.chat.v1.p'] = jsonEncode(json['messages'])
          ..['studio.application.v1.p'] = jsonEncode(json['prototype'])
          ..['studio.requirements.v1.p'] = jsonEncode(json['requirements'])
          ..['studio.historicalDecision.v1.p'] = jsonEncode(json['decision']);
        final before = Map.of(records.values);
        files.written = null;
        await c.prepareExport();
        expect(c.error, startsWith('Export blocked:'), reason: '$path');
        expect(c.error, isNot(contains('private-fixture-value')));
        expect(c.exportContents, isNull);
        expect(c.exportPreview, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        records.values.clear();
        await c.prepareExport();
        expect(c.error, isNull);
        await c.exportFile();
        expect(files.written, c.exportContents);
      }
      files.selected = clean.replaceFirst(
        'Historical only',
        'password: fixture',
      );
      await c.pickImport();
      expect(c.error, isNull);
      await c.saveCopy('retained');
      expect(
        PortableArchiveStore(records).load('retained')!.decision!.content,
        'password: fixture',
      );
    },
  );

  test('prefixed credential exports refuse independently and retry', () async {
    final records = Records();
    final files = Files();
    final c = PortableArchiveController('p', records, files: files);
    addTearDown(c.dispose);
    for (final alias in [
      'DB_PASSWORD',
      'SERVICE_API_KEY',
      'APP_DATABASE_PWD',
      'SERVICE_TOKEN',
      'APP_CLIENT_SECRET',
      'SERVICE_PRIVATE_KEY',
    ]) {
      records.values.clear();
      await c.prepareExport();
      expect(c.exportPreview, isNotNull);
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': '$alias=fixture-value'},
      ]);
      final before = Map.of(records.values);
      files.written = null;
      await c.prepareExport();
      expect(c.error, startsWith('Export blocked:'), reason: alias);
      expect(c.error, isNot(contains('fixture-value')));
      expect(c.exportPreview, isNull);
      expect(c.exportContents, isNull);
      await c.exportFile();
      expect(files.written, isNull);
      expect(records.values, before);
      records.values.clear();
      await c.prepareExport();
      expect(c.error, isNull);
      await c.exportFile();
      expect(files.written, c.exportContents);
    }
  });

  test(
    'camel-case credential exports refuse independently and retry',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      for (final alias in [
        'dbPassword',
        'serviceApiKey',
        'appDatabasePwd',
        'serviceToken',
        'appClientSecret',
        'servicePrivateKey',
      ]) {
        records.values.clear();
        await c.prepareExport();
        expect(c.exportPreview, isNotNull);
        records.values['studio.chat.v1.p'] = jsonEncode([
          {'role': 'user', 'content': '$alias=fixture-value'},
        ]);
        final before = Map.of(records.values);
        files.written = null;
        await c.prepareExport();
        expect(c.error, startsWith('Export blocked:'), reason: alias);
        expect(c.error, isNot(contains('fixture-value')));
        expect(c.exportPreview, isNull);
        expect(c.exportContents, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        records.values.clear();
        await c.prepareExport();
        expect(c.error, isNull);
        await c.exportFile();
        expect(files.written, c.exportContents);
      }
    },
  );

  test(
    'unqualified credential exports refuse independently and retry',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      for (final alias in ['token', 'secret', 'credential', 'private_key']) {
        records.values.clear();
        await c.prepareExport();
        expect(c.exportPreview, isNotNull);
        records.values['studio.chat.v1.p'] = jsonEncode([
          {'role': 'user', 'content': '$alias=fixture-value'},
        ]);
        final before = Map.of(records.values);
        files.written = null;
        await c.prepareExport();
        expect(c.error, startsWith('Export blocked:'), reason: alias);
        expect(c.error, isNot(contains('fixture-value')));
        expect(c.exportPreview, isNull);
        expect(c.exportContents, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        records.values.clear();
        await c.prepareExport();
        expect(c.error, isNull);
        await c.exportFile();
        expect(files.written, c.exportContents);
      }
    },
  );

  test(
    'API authentication token export refuses without writes and retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      await c.prepareExport();
      expect(c.exportPreview, isNotNull);
      records.values['studio.chat.v1.p'] = jsonEncode([
        {
          'role': 'user',
          'content': 'api_token=fixture-value; auth_token=fixture-value',
        },
      ]);
      final before = Map.of(records.values);
      await c.prepareExport();
      expect(c.error, startsWith('Export blocked:'));
      expect(c.error, isNot(contains('fixture-value')));
      expect(c.exportPreview, isNull);
      expect(c.exportContents, isNull);
      await c.exportFile();
      expect(files.written, isNull);
      expect(records.values, before);
      records.values.clear();
      await c.prepareExport();
      expect(c.error, isNull);
      await c.exportFile();
      expect(files.written, c.exportContents);
    },
  );

  test(
    'OAuth identity token export refuses without writes and retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      await c.prepareExport();
      expect(c.exportPreview, isNotNull);
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': 'id_token=fixture-value'},
      ]);
      final before = Map.of(records.values);
      await c.prepareExport();
      expect(c.error, startsWith('Export blocked:'));
      expect(c.error, isNot(contains('fixture-value')));
      expect(c.exportPreview, isNull);
      expect(c.exportContents, isNull);
      await c.exportFile();
      expect(files.written, isNull);
      expect(records.values, before);
      records.values.clear();
      await c.prepareExport();
      expect(c.error, isNull);
      await c.exportFile();
      expect(files.written, c.exportContents);
    },
  );

  test('Password alias export refuses without writes and retries', () async {
    final records = Records();
    final files = Files();
    final c = PortableArchiveController('p', records, files: files);
    addTearDown(c.dispose);
    await c.prepareExport();
    expect(c.exportPreview, isNotNull);
    records.values['studio.chat.v1.p'] = jsonEncode([
      {'role': 'user', 'content': 'Server=localhost;PWD=fixture-value;'},
    ]);
    final before = Map.of(records.values);
    await c.prepareExport();
    expect(c.error, startsWith('Export blocked:'));
    expect(c.error, isNot(contains('fixture-value')));
    expect(c.exportPreview, isNull);
    expect(c.exportContents, isNull);
    await c.exportFile();
    expect(files.written, isNull);
    expect(records.values, before);
    records.values.clear();
    await c.prepareExport();
    expect(c.error, isNull);
    await c.exportFile();
    expect(files.written, c.exportContents);
  });

  test('AWS configuration export refuses without writes and retries', () async {
    final records = Records();
    final files = Files();
    final c = PortableArchiveController('p', records, files: files);
    addTearDown(c.dispose);
    await c.prepareExport();
    expect(c.exportPreview, isNotNull);
    records.values['studio.chat.v1.p'] = jsonEncode([
      {'role': 'user', 'content': 'aws_secret_access_key=fixture-value'},
    ]);
    final before = Map.of(records.values);
    await c.prepareExport();
    expect(c.error, startsWith('Export blocked:'));
    expect(c.error, isNot(contains('fixture-value')));
    expect(c.exportPreview, isNull);
    expect(c.exportContents, isNull);
    await c.exportFile();
    expect(files.written, isNull);
    expect(records.values, before);
    records.values.clear();
    await c.prepareExport();
    expect(c.error, isNull);
    await c.exportFile();
    expect(files.written, c.exportContents);
  });

  test(
    'Basic authorization export refuses without writes and retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      await c.prepareExport();
      expect(c.exportPreview, isNotNull);
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': 'Authorization: Basic dXNlcjpwYXNz'},
      ]);
      final before = Map.of(records.values);
      await c.prepareExport();
      expect(c.error, startsWith('Export blocked:'));
      expect(c.error, isNot(contains('dXNlcjpwYXNz')));
      expect(c.exportPreview, isNull);
      expect(c.exportContents, isNull);
      await c.exportFile();
      expect(files.written, isNull);
      expect(records.values, before);
      records.values.clear();
      await c.prepareExport();
      expect(c.error, isNull);
      await c.exportFile();
      expect(files.written, c.exportContents);
    },
  );

  test(
    'whitespace-prefixed Basic export refuses without writes and retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      await c.prepareExport();
      expect(c.exportPreview, isNotNull);
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': 'Authorization: " \tBasic dXNlcjpwYXNz"'},
      ]);
      final before = Map.of(records.values);
      await c.prepareExport();
      expect(c.error, startsWith('Export blocked:'));
      expect(c.error, isNot(contains('dXNlcjpwYXNz')));
      expect(c.exportPreview, isNull);
      expect(c.exportContents, isNull);
      await c.exportFile();
      expect(files.written, isNull);
      expect(records.values, before);
      records.values.clear();
      await c.prepareExport();
      expect(c.error, isNull);
      await c.exportFile();
      expect(files.written, c.exportContents);
    },
  );

  test(
    'quoted whitespace credential export refuses without writes and retries',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      await c.prepareExport();
      expect(c.exportPreview, isNotNull);
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': 'password: " \tfixture-password"'},
      ]);
      final before = Map.of(records.values);
      await c.prepareExport();
      expect(c.error, startsWith('Export blocked:'));
      expect(c.error, isNot(contains('fixture-password')));
      expect(c.exportPreview, isNull);
      expect(c.exportContents, isNull);
      await c.exportFile();
      expect(files.written, isNull);
      expect(records.values, before);
      records.values.clear();
      await c.prepareExport();
      expect(c.error, isNull);
      await c.exportFile();
      expect(files.written, c.exportContents);
    },
  );

  test('password-only URL export refuses without writes and retries', () async {
    final records = Records();
    final files = Files();
    final c = PortableArchiveController('p', records, files: files);
    addTearDown(c.dispose);
    await c.prepareExport();
    expect(c.exportPreview, isNotNull);
    records.values['studio.chat.v1.p'] = jsonEncode([
      {'role': 'user', 'content': 'redis://:fixture-password@localhost'},
    ]);
    final before = Map.of(records.values);
    await c.prepareExport();
    expect(c.error, startsWith('Export blocked:'));
    expect(c.error, isNot(contains('fixture-password')));
    expect(c.exportPreview, isNull);
    expect(c.exportContents, isNull);
    await c.exportFile();
    expect(files.written, isNull);
    expect(records.values, before);
    records.values.clear();
    await c.prepareExport();
    expect(c.error, isNull);
    await c.exportFile();
    expect(files.written, c.exportContents);
  });

  testWidgets(
    'credential refusal is safe and readable at narrow enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      await ConversationStore(records).save('p', const [
        ChatMessage(role: 'user', content: 'password: private-fixture-value'),
      ]);
      final before = Map.of(records.values);
      final files = Files();
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
      final load = find.text('Load saved records for export');
      await tester.scrollUntilVisible(
        load,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(load);
      await tester.pumpAndSettle();
      final error = find.text(c.error!);
      await tester.scrollUntilVisible(
        error,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(error, findsOneWidget);
      expect(find.textContaining('private-fixture-value'), findsNothing);
      expect(find.text('Choose export file'), findsNothing);
      expect(records.values, before);
      expect(files.written, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'ambiguous saved records clear export preview and preserve retry',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      final sources = <String, String>{
        'studio.chat.v1.p':
            r'[{"role":"user","content":"lost","co\u006etent":"kept"}]',
        'studio.requirements.v1.p': '{"version":1,"revision":1,"revision":2,"requirements":[],"tasks":[]}',
        'studio.planApproval.v1.p': '{"content":"lost","content":"kept"}',
        'studio.generation.v1.p': '{"phase":"ready","phase":"failed"}',
        'studio.historicalDecision.v1.p': '{"approved":true,"approved":false}',
        'studio.historicalRevisions.v1.p':
            '[{"outcome":"ready","outcome":"failed"}]',
      };
      for (final source in sources.entries) {
        records.values.clear();
        await c.prepareExport();
        expect(c.exportPreview, isNotNull);
        files.written = null;
        records.values[source.key] = source.value;
        final before = Map.of(records.values);
        await c.prepareExport();
        expect(c.error, isNotNull, reason: source.key);
        expect(c.exportPreview, isNull, reason: source.key);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        records.values.remove(source.key);
        await c.prepareExport();
        expect(c.error, isNull);
        await c.exportFile();
        expect(files.written, isNotNull);
      }
      records.values['studio.chat.v1.p'] = jsonEncode([
        {'role': 'user', 'content': r'{"x":1,"x":2}: "quoted"'},
        {
          'role': 'assistant',
          'content': 'Exact 中文 😀',
          'planContext': 'private',
        },
      ]);
      await c.prepareExport();
      expect(c.error, isNull);
      await c.exportFile();
      final restored = PortableProjectArchive.decode(files.written!);
      expect(restored.messages.first.content, r'{"x":1,"x":2}: "quoted"');
      expect(restored.messages.last.content, 'Exact 中文 😀');
      expect(files.written, isNot(contains('private')));
    },
  );
  test(
    'unknown saved local decision fields refuse export and allow retry',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      const key = 'studio.planApproval.v1.p';
      for (final approved in [true, false]) {
        final supported = <String, Object?>{
          'messageIndex': 2,
          'content': 'Exact decision 中文 😀\nKeep this text',
          'context': 'deliberately-excluded-context',
          'approved': approved,
          'recordedAt': '2026-10-26T17:00:00.000Z',
        };
        for (final extra in <Object?>[
          'private-future-value',
          {'nested': 'private-future-value'},
          null,
        ]) {
          records.values[key] = jsonEncode(supported);
          await c.prepareExport();
          expect(c.exportPreview, isNotNull);
          files.written = null;
          records.values[key] = jsonEncode({
            ...supported,
            'futureField': extra,
          });
          final before = Map.of(records.values);
          await c.prepareExport();
          expect(c.error, isNotNull);
          expect(c.error, isNot(contains('private-future-value')));
          expect(c.exportPreview, isNull);
          await c.exportFile();
          expect(files.written, isNull);
          expect(records.values, before);
          records.values[key] = jsonEncode(supported);
          await c.prepareExport();
          await c.exportFile();
          expect(c.error, isNull);
          final decision = PortableProjectArchive.decode(files.written!)
              .decision!;
          expect(decision.content, supported['content']);
          expect(decision.approved, approved);
          expect(decision.recordedAt, DateTime.utc(2026, 10, 26, 17));
          expect(
            files.written,
            isNot(contains('deliberately-excluded-context')),
          );
          expect(files.written, isNot(contains('messageIndex')));
        }
        for (final missing in supported.keys) {
          final malformed = Map.of(supported)..remove(missing);
          records.values[key] = jsonEncode(malformed);
          files.written = null;
          await c.prepareExport();
          expect(c.error, isNotNull, reason: missing);
          expect(c.exportPreview, isNull);
          await c.exportFile();
          expect(files.written, isNull);
          expect(records.values[key], jsonEncode(malformed));
        }
      }
      records.values.clear();
      await c.prepareExport();
      expect(c.error, isNull);
      expect(c.exportPreview!.decision, isNull);
    },
  );

  test('unknown saved board fields refuse export without data loss', () async {
    final records = Records();
    final files = Files();
    final c = PortableArchiveController('p', records, files: files);
    addTearDown(c.dispose);
    final board = RequirementsBoard(
      revision: 7,
      requirements: const [
        ProjectRequirement(
          id: 'R1',
          title: 'Exact 中文 😀',
          acceptance: 'Keep all text',
        ),
      ],
      tasks: [
        DevelopmentTask(
          id: 'T1',
          requirementId: 'R1',
          title: 'First',
          status: TaskStatus.done,
        ),
        DevelopmentTask(
          id: 'T2',
          requirementId: 'R1',
          title: 'Next',
          dependencies: ['T1'],
          status: TaskStatus.inProgress,
        ),
      ],
    );
    for (final level in ['board', 'requirement', 'task']) {
      for (final value in <Object?>[
        'private-future-value',
        {'nested': 'private-future-value'},
        null,
      ]) {
        records.values.clear();
        await c.prepareExport();
        expect(c.exportPreview, isNotNull);
        files.written = null;
        final raw =
            jsonDecode(jsonEncode(board.toJson())) as Map<String, dynamic>;
        final target = switch (level) {
          'requirement' =>
            (raw['requirements'] as List).first as Map<String, dynamic>,
          'task' => (raw['tasks'] as List).last as Map<String, dynamic>,
          _ => raw,
        };
        target['futureField'] = value;
        records.values['studio.requirements.v1.p'] = jsonEncode(raw);
        final before = Map.of(records.values);
        await c.prepareExport();
        expect(c.error, isNotNull, reason: level);
        expect(c.error, isNot(contains('private-future-value')));
        expect(c.exportPreview, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        records.values['studio.requirements.v1.p'] = jsonEncode(board.toJson());
        await c.prepareExport();
        expect(c.error, isNull);
        await c.exportFile();
        expect(
          PortableProjectArchive.decode(files.written!).requirements.toJson(),
          board.toJson(),
        );
      }
    }
  });

  test(
    'malformed saved boards refuse export and absent boards stay valid',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      for (final raw in <Object?>[
        null,
        [],
        {},
        {'version': 1, 'revision': 1, 'requirements': [], 'tasks': null},
        {
          'version': 1,
          'revision': 1,
          'requirements': [null],
          'tasks': [],
        },
        {
          'version': 1,
          'revision': 1,
          'requirements': [
            {'id': 'R1', 'title': 'Missing acceptance'},
          ],
          'tasks': [],
        },
        {
          'version': 1,
          'revision': 1,
          'requirements': [],
          'tasks': [{}],
        },
        {
          'version': 1,
          'revision': 1,
          'requirements': [],
          'tasks': [],
          'future': null,
        },
      ]) {
        records.values.clear();
        await c.prepareExport();
        expect(c.exportPreview, isNotNull);
        records.values['studio.requirements.v1.p'] = jsonEncode(raw);
        final before = Map.of(records.values);
        await c.prepareExport();
        expect(c.error, isNotNull);
        expect(c.exportPreview, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
      }
      records.values.clear();
      await c.prepareExport();
      await c.exportFile();
      expect(c.error, isNull);
      expect(
        PortableProjectArchive.decode(files.written!).requirements.revision,
        0,
      );
    },
  );

  test(
    'unknown saved assistance fields refuse export without data loss',
    () async {
      final records = Records();
      final files = Files();
      final c = PortableArchiveController('p', records, files: files);
      addTearDown(c.dispose);
      for (final extra in <Map<String, Object?>>[
        {'futureField': 'private-future-value'},
        {
          'attachments': [
            {'name': 'private-future-value'},
          ],
        },
        {'futureField': null},
      ]) {
        records.values.clear();
        await c.prepareExport();
        expect(c.exportPreview, isNotNull);
        files.written = null;
        records.values['studio.chat.v1.p'] = jsonEncode([
          {'role': 'assistant', 'content': 'Exact 中文 😀', ...extra},
        ]);
        final before = Map.of(records.values);
        await c.prepareExport();
        expect(c.error, isNotNull);
        expect(c.error, isNot(contains('private-future-value')));
        expect(c.exportPreview, isNull);
        await c.exportFile();
        expect(files.written, isNull);
        expect(records.values, before);
        records.values['studio.chat.v1.p'] = jsonEncode([
          {
            'role': 'assistant',
            'content': 'Exact 中文 😀',
            'planContext': 'private-context',
          },
          {'role': 'user', 'content': 'Legacy text'},
        ]);
        await c.prepareExport();
        expect(c.error, isNull);
        await c.exportFile();
        final restored = PortableProjectArchive.decode(files.written!);
        expect(restored.messages.first.content, 'Exact 中文 😀');
        expect(restored.messages.last.content, 'Legacy text');
        expect(files.written, isNot(contains('private-context')));
      }
    },
  );

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
  test(
    'malformed saved prototype chat blocks export without changing records',
    () async {
      final records = Records();
      final prototype =
          jsonDecode(archive())['prototype'] as Map<String, dynamic>;
      for (final messages in <Object>[
        [
          {'role': 'system', 'content': 'hidden'},
        ],
        [
          {'role': 'user', 'content': 7},
        ],
        [
          {'role': 'user', 'content': 'text', 'unknown': 'secret'},
        ],
        [
          {'role': 'assistant', 'content': 'x' * 100001},
        ],
      ]) {
        records.values['studio.application.v1.p'] = jsonEncode({
          ...prototype,
          'messages': messages,
        });
        final before = Map.of(records.values);
        final c = PortableArchiveController('p', records);
        await c.prepareExport();
        expect(c.error, isNotNull);
        expect(c.exportPreview, isNull);
        expect(records.values, before);
        c.dispose();
      }
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
    expect(files.written, c.exportContents);
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
    expect(c.exportContents, isNull);
    expect(c.error, isNotNull);
  });
  test('imported workspace collisions and concurrent records refuse restore with retry', () async {
    const root = '/fixture/imported';
    final importedId = InspectedFolderStore.workspaceId(root);
    for (final concurrent in [false, true]) {
      for (final key in [
        InspectedFolderStore.key,
        'studio.importedPlan.v1.$importedId',
      ]) {
        final records = Records();
        final value = key == InspectedFolderStore.key
            ? jsonEncode([root])
            : '{}';
        if (concurrent) {
          records.beforeCommit = () => records.values[key] = value;
        } else {
          records.values[key] = value;
        }
        final c = PortableArchiveController(
          'p',
          records,
          files: Files()..selected = archive(),
        );
        addTearDown(c.dispose);
        await c.pickImport();
        await c.restoreWorkspace(importedId, 'Collision');
        expect(c.error, isNotNull);
        expect(c.importContents, archive());
        expect(records.values, {key: value});
        records.beforeCommit = null;
        await c.restoreWorkspace('unrelated', 'Recovered');
        expect(c.error, isNull);
        expect(c.importPreview, isNull);
        expect(records.values[key], value);
        expect(records.values['studio.chat.v1.$importedId'], isNull);
        expect(records.values['studio.chat.v1.unrelated'], isNotNull);
      }
    }
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
      expect(c.importContents, isNull);
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
      await c.prepareCopyExport('copy');
      expect(c.exportPreview, isNull);
      expect(c.busy, isTrue);
      c.dispose();
      final before = notifications;
      files.pending!.complete(archive());
      await picking;
      await c.prepareCopyExport('after');
      expect(c.exportPreview, isNull);
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
  testWidgets(
    'complete export review matches written snapshot without writes',
    (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      final saved = jsonDecode(archive()) as Map<String, dynamic>;
      records.values['studio.application.v1.p'] = jsonEncode(
        saved['prototype'],
      );
      final before = Map.of(records.values);
      final files = Files();
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
      final load = find.text('Load saved records for export');
      await tester.scrollUntilVisible(
        load,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(load);
      await tester.pumpAndSettle();
      final complete = find.text('Review complete archive JSON');
      await tester.scrollUntilVisible(
        complete,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(complete);
      await tester.pumpAndSettle();
      final payload = c.exportContents!;
      expect(payload, contains('"target":"private-target"'));
      expect(
        find.byWidgetPredicate((w) => w is SelectableText && w.data == payload),
        findsOneWidget,
      );
      expect(files.written, isNull);
      expect(records.values, before);
      expect(tester.takeException(), isNull);
      await tester.tap(complete);
      await tester.pumpAndSettle();
      final export = find.text('Choose export file');
      await tester.scrollUntilVisible(
        export,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(export);
      await tester.pumpAndSettle();
      expect(files.written, payload);
      expect(records.values, before);
      expect(tester.takeException(), isNull);
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
    expect(find.text('1 prototype messages'), findsOneWidget);
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
    final review = find.text('Review included text');
    await tester.scrollUntilVisible(
      review,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(review);
    await tester.pumpAndSettle();
    final editText = find.text('Change the prototype 😀');
    await tester.scrollUntilVisible(
      editText,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(editText, findsOneWidget);
    expect(records.values, isEmpty);
    final complete = find.text('Review complete archive JSON');
    await tester.scrollUntilVisible(
      complete,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(complete);
    await tester.pumpAndSettle();
    final payload = c.importContents!;
    expect(payload, contains('"target":"private-target"'));
    expect(payload, contains('"dependencies":["PrivateTask"]'));
    final exact = find.byWidgetPredicate(
      (w) => w is SelectableText && w.data == payload,
    );
    expect(exact, findsOneWidget);
    expect(records.values, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.tap(complete);
    await tester.pumpAndSettle();
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
