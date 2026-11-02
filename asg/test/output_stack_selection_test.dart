// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/controllers/project_wizard_controller.dart';
import 'package:asg/models/project_blueprint.dart';
import 'package:asg/models/project.dart';
import 'package:asg/views/project_wizard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('planned and unknown stacks refuse review and direct creation', () {
    final c = ProjectWizardController();
    addTearDown(c.dispose);
    c.discover('An HTML portfolio website');
    for (final type in ['HTML', 'Python', 'unknown']) {
      c.selectType(type);
      c.selectApproach('web');
      expect(c.type, type);
      expect(c.review(), isFalse);
      expect(c.step, CreationStep.options);
      expect(c.create('Website', 'Keep my requested stack'), isNull);
      expect(c.createFromChoices('Website'), isNull);
    }
    c.selectType('Flutter');
    expect(c.review(), isTrue);
    final project = c.createFromChoices('Website')!;
    expect(project.type, 'Flutter');
    expect(project.platforms, ['Web']);
    expect(StudioProject.fromJson(project.toJson()).type, 'Flutter');
  });
  test('changing reviewed stack invalidates review and keeps choices', () {
    final c = ProjectWizardController();
    addTearDown(c.dispose);
    c.discover('A mobile task planner');
    c.toggleFeature('Due dates', true);
    c.selectApproach('web');
    expect(c.review(), isTrue);
    c.selectType('HTML');
    expect(c.step, CreationStep.options);
    expect(c.createFromChoices('Planner'), isNull);
    expect(c.review(), isFalse);
    c.back();
    c.discover('A mobile task planner');
    expect(c.type, 'HTML');
    expect(c.features, contains('Due dates'));
    expect(c.approach?.id, 'web');
    c.selectType('Flutter');
    expect(c.review(), isTrue);
    expect(c.createFromChoices('Planner')?.type, 'Flutter');
  });
  test('disposed wizard cannot change stack or create', () {
    final c = ProjectWizardController();
    c.dispose();
    c.selectType('HTML');
    expect(c.type, 'Flutter');
    expect(c.create('Website', ''), isNull);
  });
  for (final narrow in [false, true]) {
    testWidgets(
      'explicit refusal and recovery ${narrow ? '320px 2x' : 'desktop'}',
      (tester) async {
        tester.view.physicalSize = Size(narrow ? 320 : 1000, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        StudioProject? result;
        var completed = false;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
              child: child!,
            ),
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    result = await showDialog<StudioProject>(
                      context: context,
                      builder: (_) => const ProjectWizard(),
                    );
                    completed = true;
                  },
                  child: const Text('New project'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('New project'));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextField).first,
          'An HTML portfolio website',
        );
        await tester.tap(find.text('Show my options'));
        await tester.pumpAndSettle();
        final dropdown = find.byType(DropdownButtonFormField<String>);
        await tester.ensureVisible(dropdown);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('HTML / CSS / JavaScript · Planned').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Review project'));
        await tester.pumpAndSettle();
        expect(completed, isFalse);
        expect(
          find.textContaining('is planned and cannot be created yet'),
          findsOneWidget,
        );
        expect(find.text('Create project'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(dropdown);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Flutter / Dart · Implemented path').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Review project'));
        await tester.pumpAndSettle();
        expect(find.text('Output stack: Flutter / Dart'), findsOneWidget);
        await tester.tap(find.text('Back'));
        await tester.pumpAndSettle();
        expect(find.text('Flutter / Dart · Implemented path'), findsOneWidget);
        await tester.tap(find.text('Review project'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Create project'));
        await tester.pumpAndSettle();
        expect(completed, isTrue);
        expect(result?.type, 'Flutter');
        expect(result?.platforms, ['Web']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
