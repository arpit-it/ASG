// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/services/local_application_actions.dart';

void main() {
  const initial = AppDefinition(
    title: 'Demo',
    theme: 'indigo',
    elements: [
      AppElement(id: 'welcome', kind: ElementKind.heading, label: 'Welcome'),
    ],
  );
  test(
    'compound supported edits create a counter and change the live theme',
    () {
      final result = LocalApplicationActions().apply(
        initial,
        'add a counter and change the theme to green',
      )!;
      expect(result.definition.theme, 'green');
      expect(result.definition.elements.last.kind, ElementKind.counter);
      expect(initial.elements, hasLength(1));
    },
  );
  test('unrecognized compound requests are never partially applied', () {
    expect(
      LocalApplicationActions().apply(
        initial,
        'add a counter and deploy it to the internet',
      ),
      isNull,
    );
    expect(initial.elements, hasLength(1));
  });
}
