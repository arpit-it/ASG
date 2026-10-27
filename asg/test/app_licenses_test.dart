// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/services/studio_store.dart';
import 'package:asg/views/app_licenses_button.dart';
import 'package:asg/views/studio_app.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled ASG notices retain canonical license and owner attribution',
    () {
      final license = File('../LICENSE').readAsStringSync();
      final notice = File('../NOTICE').readAsStringSync();
      expect(File('NOTICES').readAsStringSync(), '$notice\n$license');
      expect(
        File('assets/legal/ASG_NOTICES.txt').readAsStringSync(),
        '$notice\n$license',
      );
      expect(notice, contains('Copyright 2026 Arpit Sinha'));
      for (final root in ['lib', 'test', 'tools']) {
        for (final file in Directory(
          root,
        ).listSync(recursive: true).whereType<File>()) {
          if (file.path.endsWith('.dart') || file.path.endsWith('.py')) {
            expect(
              file.readAsStringSync().split('\n').first,
              contains('SPDX-License-Identifier: MPL-2.0'),
              reason: file.path,
            );
          }
        }
      }
    },
  );

  test(
    'Flutter bundled license asset includes ASG and third-party notices',
    () async {
      // The test binding suppresses registry collectors; inspect the actual
      // generated bundle read by the production services binding instead.
      final bytes = await rootBundle.load('NOTICES.Z');
      final text = utf8.decode(gzip.decode(bytes.buffer.asUint8List()));
      expect(text, contains('asg\n\n'));
      expect(text, contains('Copyright 2026 Arpit Sinha'));
      expect(text, contains('Mozilla Public License'));
      expect(text, contains('Limitation of Liability'));
      expect(text, contains('flutter\n'));
    },
  );

  testWidgets('home opens offline licenses at narrow enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    SharedPreferences.setMockInitialValues({});
    final store = StudioStore.fromPreferences(
      await SharedPreferences.getInstance(),
    );
    await tester.pumpWidget(StudioApp(store: store));
    expect(
      MediaQuery.textScalerOf(tester.element(find.byTooltip('Licenses')))
          .scale(10),
      20,
    );
    await tester.tap(find.byTooltip('Licenses'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.textContaining('Copyright © 2026 Arpit Sinha'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byTooltip('Licenses'), findsOneWidget);
  });

  testWidgets('license navigation can be disabled during pending work', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: AppLicensesButton(enabled: false)),
      ),
    );
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    await tester.tap(find.byTooltip('Licenses'));
    await tester.pumpAndSettle();
    expect(find.byType(LicensePage), findsNothing);
  });
}
