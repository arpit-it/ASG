// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:asg/controllers/html_export_controller.dart';
import 'package:asg/controllers/project_wizard_controller.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/services/html/html_source_export_factory.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/dashboard.dart';
import 'package:asg/views/html_export_screen.dart';
import 'package:asg/views/project_wizard.dart';
import 'package:asg/views/studio_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Records implements RecordStorage {
  int writes = 0;
  @override
  String? getString(String key) => null;
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    throw StateError('Draft handoff must not save a project.');
  }
}

Future<void> selectHtml(WidgetTester tester) async {
  final dropdown = find.byType(DropdownButtonFormField<String>);
  await tester.ensureVisible(dropdown);
  await tester.tap(dropdown);
  await tester.pumpAndSettle();
  await tester.tap(find.text('HTML / CSS / JavaScript · Planned').last);
  await tester.pumpAndSettle();
}

void main() {
  test('draft requires live HTML options and bounded original plain text', () {
    final c = ProjectWizardController();
    expect(c.htmlStarterDraft(), isNull);
    c.discover('A portfolio website <script> stays plain text');
    expect(c.htmlStarterDraft(), isNull);
    c.selectType('HTML');
    expect(c.htmlStarterDraft()!.title, 'My Website');
    expect(
      c.htmlStarterDraft()!.description,
      'A portfolio website <script> stays plain text',
    );
    c.selectType('Python');
    expect(c.htmlStarterDraft(), isNull);
    c.selectType('HTML');
    c.back();
    expect(c.htmlStarterDraft(), isNull);
    c.discover('x' * 2001);
    expect(c.htmlStarterDraft(), isNull);
    expect(c.error, contains('1–2000'));
    c.discover('A portfolio website');
    c.dispose();
    expect(c.htmlStarterDraft(), isNull);
  });
  test(
    'seed carries no destination, review, saved record or export authority',
    () {
      final c = HtmlExportController(
        exporter: createHtmlSourceExport(),
        initialInput: HtmlSiteInput(
          title: 'My site',
          description: 'Original idea',
        ),
      );
      expect(c.title, 'My site');
      expect(c.description, 'Original idea');
      expect(c.folder, isEmpty);
      expect(c.parent, isEmpty);
      expect(c.review, isNull);
      expect(c.exportedDirectory, isNull);
      expect(c.saved, false);
      expect(c.sourceCheck, isNull);
      expect(c.preview.url, isNull);
      c.dispose();
    },
  );
  for (final home in [false, true]) {
    for (final narrow in [false, true]) {
      testWidgets(
        'actual ${home ? 'home' : 'dashboard'} handoff and return ${narrow ? '320px 2x' : 'desktop'}',
        (tester) async {
          tester.view.physicalSize = Size(narrow ? 320 : 1200, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final records = _Records();
          final store = StudioStore(records);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
                child: child!,
              ),
              home: home
                  ? StudioHome(store: store, projects: const [])
                  : Dashboard(store: store, initialProjects: const []),
            ),
          );
          final create = find.text('Let’s create something');
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            create,
            150,
            scrollable: find
                .descendant(
                  of: find.byType(ListView).first,
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(create);
          await tester.tap(create);
          await tester.pumpAndSettle();
          await tester.enterText(
            find
                .descendant(
                  of: find.byType(ProjectWizard),
                  matching: find.byType(TextField),
                )
                .first,
            'A portfolio website with my original idea',
          );
          await tester.ensureVisible(find.text('Show my options'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Show my options'));
          await tester.pumpAndSettle();
          await selectHtml(tester);
          final open = find.text('Open fixed HTML starter');
          await tester.ensureVisible(open);
          await tester.tap(open);
          await tester.pumpAndSettle();
          final screen = tester.widget<HtmlExportScreen>(
            find.byType(HtmlExportScreen),
          );
          expect(screen.controller.title, 'My Website');
          expect(
            screen.controller.description,
            'A portfolio website with my original idea',
          );
          expect(screen.controller.review, isNull);
          expect(screen.controller.parent, isEmpty);
          expect(screen.controller.exportedDirectory, isNull);
          expect(records.writes, 0);
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(find.byType(ProjectWizard), findsOneWidget);
          expect(
            find.text('HTML / CSS / JavaScript · Planned'),
            findsOneWidget,
          );
          await tester.tap(find.text('Back'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(
                  find
                      .descendant(
                        of: find.byType(ProjectWizard),
                        matching: find.byType(TextField),
                      )
                      .first,
                )
                .controller!
                .text,
            'A portfolio website with my original idea',
          );
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(records.writes, 0);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }
  testWidgets('pending handoff cannot duplicate; disposal never updates view', (
    tester,
  ) async {
    final gate = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectWizard(
            onOpenHtmlStarter: (_) {
              calls++;
              return gate.future;
            },
          ),
        ),
      ),
    );
    await tester.enterText(
      find
          .descendant(
            of: find.byType(ProjectWizard),
            matching: find.byType(TextField),
          )
          .first,
      'A portfolio website',
    );
    await tester.tap(find.text('Show my options'));
    await tester.pumpAndSettle();
    await selectHtml(tester);
    await tester.ensureVisible(find.text('Open fixed HTML starter'));
    await tester.tap(find.text('Open fixed HTML starter'));
    await tester.pump();
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Starter open'),
          )
          .onPressed,
      isNull,
    );
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox());
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
