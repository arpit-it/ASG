// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/models/git_head_observation.dart';
import 'package:asg/controllers/imported_git_metadata_controller.dart';
import 'package:asg/views/git_metadata_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_git_metadata_controller_test.dart';

void main() {
  testWidgets('opening and cancelling dialog never start helper', (
    tester,
  ) async {
    final host = MetadataHostFixture(), setup = SetupFixture();
    final c = controllerFixture(host, setup);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              GitMetadataPanel(
                root: c.root,
                records: NoWriteRecords(),
                controller: c,
              ),
            ],
          ),
        ),
      ),
    );
    expect(host.requests, isEmpty);
    expect(setup.loads, 0);
    await tester.tap(find.text('Read Git metadata'));
    await tester.pumpAndSettle();
    expect(find.text('Read local Git metadata?'), findsOneWidget);
    expect(find.text('Folder: /selected/folder'), findsOneWidget);
    expect(host.requests, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(host.requests, isEmpty);
    expect(c.confirming, isFalse);
    await tester.pumpWidget(const SizedBox());
    expect(host.disposals, 1);
  });
  testWidgets(
    'explicit confirm shows literal data and stale failure honestly',
    (tester) async {
      final host = MetadataHostFixture(),
          c = controllerFixture(MetadataHostFixture(), SetupFixture());
      c.dispose();
      final controller = controllerFixture(host, SetupFixture());
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                GitMetadataPanel(
                  root: controller.root,
                  records: NoWriteRecords(),
                  controller: controller,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.text('Read Git metadata'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read metadata'));
      await tester.pumpAndSettle();
      expect(host.requests, hasLength(1));
      expect(find.text('Declared reference: refs/heads/main'), findsOneWidget);
      expect(
        find.text(
          'Working tree: unknown · Ahead/behind: unknown · Conflicts: unknown',
        ),
        findsOneWidget,
      );
      host.read = () => Future.error(StateError('private-sentinel'));
      await tester.ensureVisible(find.text('Read Git metadata'));
      await tester.tap(find.text('Read Git metadata'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read metadata'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Previous reading retained'), findsOneWidget);
      expect(find.text('Declared reference: refs/heads/main'), findsOneWidget);
      expect(find.textContaining('private-sentinel'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('unsupported host cannot read setup or launch', (tester) async {
    final host = MetadataHostFixture()..supported = false,
        setup = SetupFixture();
    final c = controllerFixture(host, setup);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitMetadataPanel(
            root: c.root,
            records: NoWriteRecords(),
            controller: c,
          ),
        ),
      ),
    );
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Read Git metadata'),
    );
    expect(button.onPressed, isNull);
    expect(setup.loads, 0);
    expect(host.requests, isEmpty);
  });
  testWidgets('busy read has Stop and late cancelled data is discarded', (
    tester,
  ) async {
    final host = MetadataHostFixture(),
        c = controllerFixture(MetadataHostFixture(), SetupFixture());
    c.dispose();
    final controller = controllerFixture(host, SetupFixture());
    final pending = Completer<GitHeadObservation>();
    host.read = () => pending.future;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GitMetadataPanel(
            root: controller.root,
            records: NoWriteRecords(),
            controller: controller,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Read Git metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read metadata'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Stop inspection'), findsOneWidget);
    await tester.tap(find.text('Stop inspection'));
    await tester.pump();
    pending.complete(sampleObservation());
    await tester.pumpAndSettle();
    expect(find.text('Declared reference: refs/heads/main'), findsNothing);
    expect(find.textContaining('Inspection cancelled.'), findsOneWidget);
  });
  testWidgets('changed panel context invalidates pending confirmation', (
    tester,
  ) async {
    final firstHost = MetadataHostFixture(), nextHost = MetadataHostFixture();
    final first = controllerFixture(firstHost, SetupFixture());
    final next = ImportedGitMetadataController(
      root: '/different/folder',
      host: nextHost,
      setupStore: SetupFixture(),
    );
    final records = NoWriteRecords();
    Widget screen(ImportedGitMetadataController c) => MaterialApp(
      home: Scaffold(
        body: GitMetadataPanel(root: c.root, records: records, controller: c),
      ),
    );
    await tester.pumpWidget(screen(first));
    await tester.tap(find.text('Read Git metadata'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(screen(next));
    await tester.pump();
    expect(first.isDisposed, isTrue);
    await tester.tap(find.text('Read metadata'));
    await tester.pumpAndSettle();
    expect(firstHost.requests, isEmpty);
    expect(nextHost.requests, isEmpty);
    await tester.tap(find.text('Read Git metadata'));
    await tester.pumpAndSettle();
    expect(find.text('Folder: /different/folder'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
  testWidgets('narrow enlarged panel and confirmation remain usable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final host = MetadataHostFixture(),
        c = controllerFixture(MetadataHostFixture(), SetupFixture());
    c.dispose();
    final controller = controllerFixture(host, SetupFixture());
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ListView(
            children: [
              GitMetadataPanel(
                root: controller.root,
                records: NoWriteRecords(),
                controller: controller,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('Read Git metadata'));
    await tester.tap(find.text('Read Git metadata'));
    await tester.pumpAndSettle();
    expect(find.text('Read local Git metadata?'), findsOneWidget);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(host.requests, isEmpty);
  });
}
