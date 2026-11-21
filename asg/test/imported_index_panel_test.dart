// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/services/imported_index_store.dart';
import 'package:asg/views/imported_index_panel.dart';

import 'imported_index_controller_test.dart'
    show indexRecords, indexController, IndexHost;

void main() {
  testWidgets(
    'panel never starts automatically; Cancel is inert and confirmed read shows dated declarations',
    (t) async {
      final r = await indexRecords(), h = IndexHost();
      final c = indexController(r, h);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ImportedIndexPanel(
                root: '/project',
                records: r,
                controller: c,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(h.calls, 0);
      await t.tap(find.text('Review index read'));
      await t.pumpAndSettle();
      expect(find.text('Read local index declarations?'), findsOneWidget);
      expect(h.calls, 0);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(h.calls, 0);
      expect(c.confirming, false);
      await t.tap(find.text('Review index read'));
      await t.pumpAndSettle();
      await t.tap(find.text('Read index'));
      await t.pumpAndSettle();
      expect(h.calls, 1);
      expect(find.text('Completed index read'), findsOneWidget);
      expect(c.observationCurrent, true);
      await t.tap(find.text('Index read details'));
      await t.pumpAndSettle();
      expect(find.text('lib/main.dart'), findsOneWidget);
      expect(find.textContaining('Index SHA-256:'), findsOneWidget);
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    },
  );
  testWidgets('runtime changed during open consent cannot dispatch a reader', (
    t,
  ) async {
    final r = await indexRecords(), h = IndexHost();
    final c = indexController(r, h);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImportedIndexPanel(root: '/project', records: r, controller: c),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Review index read'));
    await t.pumpAndSettle();
    r.values[ImportedIndexStore.runtimeKey] = 'changed';
    await t.tap(find.text('Read index'));
    await t.pumpAndSettle();
    expect(h.calls, 0);
    expect(c.observation, isNull);
    expect(c.error, isNotNull);
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
  testWidgets(
    'Stop is available during a delayed read and cannot publish a late result',
    (t) async {
      final r = await indexRecords(), h = IndexHost()..gate = Completer();
      final c = indexController(r, h);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ImportedIndexPanel(
              root: '/project',
              records: r,
              controller: c,
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Review index read'));
      await t.pumpAndSettle();
      await t.tap(find.text('Read index'));
      await t.pump(const Duration(milliseconds: 300));
      expect(h.calls, 1);
      expect(find.text('Stop index read'), findsOneWidget);
      await t.tap(find.text('Stop index read'));
      await t.pumpAndSettle();
      expect(c.busy, false);
      expect(c.observation, isNull);
      expect(h.cancels, 1);
      expect(ImportedIndexStore(r).readBusy, false);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    },
  );
  testWidgets(
    'unsupported narrow enlarged-text panel stays readable with action disabled',
    (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final r = await indexRecords(), h = IndexHost()..available = false;
      final c = indexController(r, h);
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ImportedIndexPanel(
                root: '/project',
                records: r,
                controller: c,
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(
        find.text('Local index inspection is unavailable on this platform.'),
        findsOneWidget,
      );
      expect(
        t
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Review index read'),
            )
            .onPressed,
        isNull,
      );
      expect(h.calls, 0);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    },
  );
  testWidgets('observed details wrap at narrow width and enlarged text', (
    t,
  ) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final r = await indexRecords(), h = IndexHost();
    final c = indexController(r, h);
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImportedIndexPanel(
              root: '/project',
              records: r,
              controller: c,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Review index read'));
    await t.pumpAndSettle();
    await t.tap(find.text('Read index'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('Index read details'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await t.ensureVisible(find.text('Index read details'));
    await t.tap(find.text('Index read details'));
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('lib/main.dart'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('lib/main.dart'), findsOneWidget);
    expect(c.observationCurrent, true);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump();
  });
}
