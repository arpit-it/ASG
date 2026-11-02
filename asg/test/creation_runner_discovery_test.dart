// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/project_wizard_controller.dart';
import 'package:asg/views/project_wizard.dart';
import 'package:asg/views/runner_capabilities.dart';
import 'package:flutter/material.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/html_source_check.dart';
import 'package:asg/models/project_runner.dart';
import 'package:asg/services/html/html_preview.dart';
import 'package:asg/services/html/html_source_check.dart';
import 'package:asg/services/html/html_starter_runner.dart';
import 'package:asg/services/project_runner_registry.dart';
import 'package:flutter_test/flutter_test.dart';

class _Checker implements HtmlSourceChecker {
  bool available = true;
  int calls = 0;
  Completer<HtmlSourceCheck>? pending;
  @override
  bool get supported => available;
  @override
  Future<HtmlSourceCheck> check({
    required String directory,
    required HtmlSiteInput input,
    required void Function() authorizeRead,
  }) async {
    calls++;
    return pending == null
        ? const HtmlSourceCheck(files: 5, bytes: 123)
        : await pending!.future;
  }
}

class _Preview implements HtmlPreview {
  bool available = true;
  int starts = 0, opens = 0, stops = 0;
  @override
  bool get supported => available;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
  }) async {
    starts++;
    return Uri.parse('http://127.0.0.1:1234/token/');
  }

  @override
  Future<void> open() async {
    opens++;
  }

  @override
  Future<void> stop() async {
    stops++;
  }
}

void main() {
  test(
    'selected host discovery preserves creation refusal and never dispatches',
    () {
      final checker = _Checker()..available = false;
      final preview = _Preview();
      final c = ProjectWizardController(
        runners: ProjectRunnerRegistry(
          html: HtmlStarterRunner(checker: checker, preview: preview),
        ),
      );
      expect(c.runnerDescriptor, isNull);
      c.discover('A portfolio website');
      c.selectType('HTML');
      expect(
        c.runnerDescriptor!
            .capability(RunnerOperation.checkSources)
            .availability,
        RunnerAvailability.unavailableHost,
      );
      expect(
        c.runnerDescriptor!.capability(RunnerOperation.run).canDispatch,
        true,
      );
      expect(c.outputStack!.canCreate, false);
      expect(c.review(), false);
      expect(c.create('Site', 'Description'), isNull);
      for (final type in ['Python', 'Flutter', 'unknown']) {
        c.selectType(type);
        expect(c.runnerDescriptor, isNull);
      }
      expect(checker.calls + preview.starts + preview.opens + preview.stops, 0);
      c.dispose();
    },
  );
  test('default discovery reflects actual native host boundaries', () {
    final c = ProjectWizardController()..selectType('HTML');
    final d = c.runnerDescriptor!;
    expect(d.id, 'asg-fixed-html');
    expect(d.version, '1.0.0');
    expect(d.adapterId, 'asg-static-html-v1');
    expect(
      d.capability(RunnerOperation.checkSources).canDispatch,
      Platform.isMacOS,
    );
    expect(d.capability(RunnerOperation.run).canDispatch, Platform.isMacOS);
    c.dispose();
  });
  for (final available in [true, false]) {
    for (final narrow in [true, false]) {
      testWidgets(
        'creation capability interaction host=$available narrow=$narrow',
        (tester) async {
          tester.view.physicalSize = Size(narrow ? 320 : 1200, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final checker = _Checker()..available = available;
          final preview = _Preview()..available = available;
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
                child: child!,
              ),
              home: Scaffold(
                body: ProjectWizard(
                  runners: ProjectRunnerRegistry(
                    html: HtmlStarterRunner(checker: checker, preview: preview),
                  ),
                ),
              ),
            ),
          );
          await tester.enterText(
            find.byType(TextField).first,
            'A portfolio website',
          );
          await tester.ensureVisible(find.text('Show my options'));
          await tester.tap(find.text('Show my options'));
          await tester.pumpAndSettle();
          Future<void> select(String label) async {
            final dropdown = find.byType(DropdownButtonFormField<String>);
            await tester.ensureVisible(dropdown);
            await tester.tap(dropdown);
            await tester.pumpAndSettle();
            await tester.tap(find.text(label).last);
            await tester.pumpAndSettle();
          }

          await select('HTML / CSS / JavaScript · Planned');
          await tester.ensureVisible(find.text('Runner capabilities'));
          await tester.tap(find.text('Runner capabilities'));
          await tester.pumpAndSettle();
          expect(find.text('asg-fixed-html v1.0.0'), findsOneWidget);
          final panel = tester.widget<RunnerCapabilities>(
            find.byType(RunnerCapabilities),
          );
          expect(
            panel.descriptor.capability(RunnerOperation.run).canDispatch,
            available,
          );
          final reason = available
              ? 'Available: Serve an unchanged starter snapshot on an owned loopback preview.'
              : 'Unavailable on this host: Requires the macOS fixed-starter host.';
          await tester.ensureVisible(find.text(reason).first);
          await tester.pumpAndSettle();
          expect(
            find.text(reason),
            available ? findsOneWidget : findsNWidgets(3),
          );
          expect(
            find.textContaining(
              'browser installation and version are not verified here',
            ),
            findsOneWidget,
          );
          expect(
            find.textContaining('Not implemented: No project test runner'),
            findsOneWidget,
          );
          expect(
            find.textContaining('Not applicable: Static HTML'),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await select('Python · Planned');
          expect(find.byType(RunnerCapabilities), findsNothing);
          await select('Flutter / Dart · Implemented path');
          expect(find.byType(RunnerCapabilities), findsNothing);
          expect(
            checker.calls + preview.starts + preview.opens + preview.stops,
            0,
          );
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
