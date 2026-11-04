// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/base_controller.dart';
import 'package:asg/controllers/requirements_controller.dart';
import 'package:asg/controllers/html_export_controller.dart';
import 'package:asg/views/html_project_workspace.dart';
import 'package:asg/views/html_export_screen.dart';
import 'package:asg/views/requirements_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_planning_test.dart' as seed;

void main() {
  for (final export in [false, true]) {
    testWidgets(
      'HTML ${export ? "export" : "requirements"} route retains owner across theme and resize',
      (tester) async {
        final records = await seed.seed();
        late StateSetter changeTheme;
        var dark = false;
        await tester.pumpWidget(
          StatefulBuilder(
            builder: (_, setState) {
              changeTheme = setState;
              return MaterialApp(
                theme: ThemeData(
                  brightness: dark ? Brightness.dark : Brightness.light,
                ),
                home: HtmlProjectWorkspace(
                  project: seed.project,
                  records: records,
                ),
              );
            },
          ),
        );
        final link = find.text(
          export ? 'Open HTML starter' : 'Requirements and tasks',
        );
        await tester.ensureVisible(link);
        await tester.tap(link);
        await tester.pumpAndSettle();
        BaseController owner() => export
            ? tester
                  .widget<HtmlExportScreen>(find.byType(HtmlExportScreen))
                  .controller
            : tester
                  .widget<RequirementsScreen>(find.byType(RequirementsScreen))
                  .controller;
        final original = owner();
        if (export) {
          final titleField = find.widgetWithText(TextField, 'Site title');
          final exportOwner = original as HtmlExportController;
          if (exportOwner.supported) {
            await tester.enterText(titleField, 'Retained draft');
          } else {
            // Unsupported hosts keep inputs disabled. Exercise route-owned
            // draft state without claiming export or enabled UI support.
            expect(tester.widget<TextField>(titleField).enabled, false);
            exportOwner.edit(title: 'Retained draft');
          }
        } else {
          expect(
            (owner() as RequirementsController)
                .board!
                .requirements
                .single
                .title,
            'Navigation',
          );
        }
        changeTheme(() => dark = true);
        await tester.pumpAndSettle();
        expect(
          owner(),
          same(original),
          reason: 'Route dependency rebuild must retain workflow and listener ownership',
        );
        if (export) {
          expect((owner() as HtmlExportController).title, 'Retained draft');
        } else {
          expect(
            (owner() as RequirementsController)
                .board!
                .requirements
                .single
                .title,
            'Navigation',
          );
        }
        tester.view.physicalSize = const Size(900, 700);
        addTearDown(tester.view.resetPhysicalSize);
        await tester.pumpAndSettle();
        expect(owner(), same(original));
        expect(original.isDisposed, false);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(original.isDisposed, true);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
