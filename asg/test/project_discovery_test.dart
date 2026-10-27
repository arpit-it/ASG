// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/project_wizard_controller.dart';
import 'package:asg/models/project_blueprint.dart';
import 'package:asg/services/project_discovery.dart';

void main() {
  test('suggestions are based on intent and target language', () {
    final service = ProjectDiscovery();
    expect(
      service.suggest('A mobile task planner').recommendedApproach,
      'mobile',
    );
    expect(service.suggest('A portfolio website').recommendedApproach, 'web');
    expect(
      service.suggest('A desktop inventory tool').features,
      contains('Reports'),
    );
  });
  test('review is required and choices are retained when navigating back', () {
    final c = ProjectWizardController();
    expect(c.createFromChoices('Planner'), isNull);
    expect(c.discover('todo'), false);
    expect(c.discover('A mobile task planner'), true);
    expect(c.step, CreationStep.options);
    c.selectApproach('web');
    c.toggleFeature('Due dates', true);
    c.review();
    c.back();
    expect(c.features, contains('Due dates'));
    expect(c.approach?.id, 'web');
    c.review();
    final project = c.createFromChoices('Planner')!;
    expect(project.platforms, ['Web']);
    expect(project.type, 'Flutter');
    expect(project.description, contains('Due dates'));
    c.dispose();
  });
  test(
    'editing an idea refreshes suggestions instead of retaining stale features',
    () {
      final c = ProjectWizardController();
      c.discover('A mobile task planner');
      c.back();
      c.discover('An inventory tool for my business');
      expect(c.features, contains('Overview dashboard'));
      expect(c.features, isNot(contains('Task list')));
      c.dispose();
    },
  );
}
