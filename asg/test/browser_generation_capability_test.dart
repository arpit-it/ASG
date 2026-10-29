// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('browser')
library;

import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/generation_host_factory.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/source_generation_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast_web/sembast_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

const project = StudioProject(
  id: 'browser-capability',
  name: 'Browser capability',
  description: 'Disposable unavailable-host check',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'production browser host refuses native commands without callbacks',
    () async {
      final host = createGenerationHost();
      addTearDown(host.dispose);
      expect(host.supported, isFalse);
      expect(FolderPicker().supported, isFalse);
      final generated = GeneratedProject(
        directory: '/disposable-generated',
        sdk: '/not-used',
        python: 'python3',
        sources: {'lib/main.dart': '0' * 64},
      );
      var writes = 0, progress = 0;
      await expectLater(
        host.generate(
          project: project,
          definition: const AppDefinition(
            title: 'Browser capability',
            theme: 'indigo',
            elements: [],
          ),
          parent: '/not-used',
          name: 'not_used',
          sdk: '/not-used',
          python: 'python3',
          authorizeWrite: () => writes++,
        ),
        throwsUnsupportedError,
      );
      for (final resume in [false, true]) {
        await expectLater(
          host.verify(generated, (_) async {
            progress++;
          }, resume: resume),
          throwsUnsupportedError,
        );
      }
      await expectLater(host.startPreview(generated), throwsUnsupportedError);
      await expectLater(
        host.openPreview(Uri.parse('http://127.0.0.1:1/')),
        throwsUnsupportedError,
      );
      host.cancelVerification();
      await host.stopPreview();
      expect(writes, 0);
      expect(progress, 0);
    },
  );

  testWidgets(
    'web Build stays unavailable after consent and preserves IndexedDB records',
    (tester) async {
      final name = 'asg-capability-${DateTime.now().microsecondsSinceEpoch}';
      SharedPreferences.setMockInitialValues({});
      late SharedPreferences prefs;
      late Database db;
      late StudioDatabase records;
      await tester.runAsync(() async {
        prefs = await SharedPreferences.getInstance();
        db = await databaseFactoryWeb.openDatabase(name);
        records = await StudioDatabase.migrate(db, prefs);
      });
      try {
        final applications = ApplicationStore(records);
        final definition = applications.load(project).definition;
        final store = SourceGenerationStore(records);
        await tester.runAsync(() async {
          await applications.save(
            project.id,
            ApplicationSnapshot(definition, const [], 7),
          );
          await store.save(
            project.id,
            GeneratedProject(
              directory: '/retained-native-record',
              sdk: '/not-used',
              python: 'python3',
              sources: {'lib/main.dart': '0' * 64},
            ),
          );
        });
        final keys = [
          'studio.application.v1.${project.id}',
          'studio.generation.v1.${project.id}',
        ];
        final before = {for (final key in keys) key: records.getString(key)};
        final controller = SourceGenerationController(
          project: project,
          definition: definition,
          store: store,
          host: createGenerationHost(),
        );
        await tester.pumpWidget(
          MaterialApp(home: SourceGenerationScreen(controller: controller)),
        );
        expect(
          find.textContaining('Generation currently requires the macOS app'),
          findsOneWidget,
        );
        expect(controller.available, isFalse);
        final scrollable = find.byType(Scrollable).first;
        for (final tooltip in [
          'Choose Existing parent directory',
          'Choose Installed Flutter SDK directory',
        ]) {
          final control = find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == tooltip,
          );
          await tester.scrollUntilVisible(control, 150, scrollable: scrollable);
          expect(tester.widget<IconButton>(control).onPressed, isNull);
        }
        await tester.scrollUntilVisible(
          find.byType(Checkbox),
          150,
          scrollable: scrollable,
        );
        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
        final generate = find.widgetWithText(
          FilledButton,
          'Generate, test and build',
        );
        expect(tester.widget<FilledButton>(generate).onPressed, isNull);
        expect(
          await controller.generate(
            parent: '/not-used',
            name: 'not_used',
            sdk: '/not-used',
            python: 'python3',
            approved: true,
          ),
          isFalse,
        );
        expect(await controller.verifyAgain(approved: true), isFalse);
        expect(
          await controller.verifyAgain(approved: true, resume: true),
          isFalse,
        );
        await controller.startPreview();
        expect(controller.preview, isNull);
        expect(controller.busy, isFalse);
        expect(controller.error, isNull);
        expect({for (final key in keys) key: records.getString(key)}, before);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await db.close();
          db = await databaseFactoryWeb.openDatabase(name);
          final reopened = await StudioDatabase.migrate(db, prefs);
          expect({
            for (final key in keys) key: reopened.getString(key),
          }, before);
          expect(ApplicationStore(reopened).load(project).revision, 7);
          expect(
            SourceGenerationStore(reopened).load(project.id)!.directory,
            '/retained-native-record',
          );
        });
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await db.close();
          await databaseFactoryWeb.deleteDatabase(name);
        });
      }
    },
  );
}
