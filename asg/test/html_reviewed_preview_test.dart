// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/controllers/html_reviewed_preview_controller.dart';
import 'package:asg/controllers/html_reviewed_export_controller.dart';
import 'package:asg/views/html_reviewed_export_screen.dart';

import 'html_reviewed_source_check_test.dart' as fixtures;

import 'package:asg/services/html/html_reviewed_preview.dart';
import 'package:asg/views/html_reviewed_preview_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

HtmlSourceProposal source() => HtmlSourceProposal.decode(
  jsonEncode({
    'summary': 'Passive site',
    'files': {
      'index.html': '<!doctype html><link rel="stylesheet" href="styles.css"><h1>Passive</h1><script>document.body.dataset.ran="yes"</script><script src="app.js"></script>',
      'styles.css': 'h1 { color: rgb(0, 128, 0); }',
      'app.js': 'document.body.dataset.ran="yes";',
    },
  }),
);

class Preview implements HtmlReviewedPreview {
  @override
  bool get supported => true;
  int starts = 0, stops = 0, opens = 0, authorizedReads = 0;
  bool failStop = false;
  Completer<void>? pendingOpen;
  void Function()? authority;
  Completer<Uri> pending = Completer();
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  }) {
    starts++;
    authority = authorizeRead;
    authorizeRead();
    authorizedReads++;
    return pending.future;
  }

  @override
  Future<void> open() async {
    opens++;
    await pendingOpen?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('cleanup failed');
  }
}

void main() {
  HtmlReviewedPreviewController controller(
    Preview p, {
    void Function()? authorize,
    Duration deadline = const Duration(seconds: 10),
  }) => HtmlReviewedPreviewController(
    proposal: source(),
    directory: '/export',
    preview: p,
    authorizeSource: authorize ?? () {},
    deadline: deadline,
  );
  for (final revokeAt in [1, 2, 3]) {
    for (final dispose in [false, true]) {
      test(
        'startup authority callback $revokeAt ${dispose ? 'disposal' : 'Stop'} revokes startup and publication',
        () async {
          final p = Preview();
          var calls = 0;
          var revoke = true;
          late HtmlReviewedPreviewController c;
          c = controller(
            p,
            authorize: () {
              calls++;
              if (revoke && calls == revokeAt) {
                revoke = false;
                if (dispose) {
                  c.dispose();
                } else {
                  unawaited(c.stop());
                }
              }
            },
          );
          p.pending.complete(Uri.parse('http://127.0.0.1:123/revoked/'));
          await c.confirm();
          expect(c.url, isNull);
          expect(p.starts, revokeAt == 1 ? 0 : 1);
          if (revokeAt == 2) {
            expect(
              calls,
              2,
              reason:
                  'read authorization must throw before returning to service',
            );
          }
          expect(p.authorizedReads, revokeAt < 3 ? 0 : 1);
          expect(c.busy, false);
          if (!dispose) {
            p.pending = Completer()
              ..complete(Uri.parse('http://127.0.0.1:123/fresh/'));
            await c.confirm();
            expect(c.url, Uri.parse('http://127.0.0.1:123/fresh/'));
            await c.open();
            expect(p.opens, 1);
            c.dispose();
          }
        },
      );
    }
  }
  for (final disposeDuringOpen in [false, true]) {
    test(
      'opening notification ${disposeDuringOpen ? 'disposal' : 'Stop'} prevents browser dispatch',
      () async {
        final p = Preview();
        final c = controller(p);
        p.pending.complete(Uri.parse('http://127.0.0.1:123/token/'));
        await c.confirm();
        var revoked = false;
        c.addListener(() {
          if (!c.opening || revoked) return;
          revoked = true;
          if (disposeDuringOpen) {
            c.dispose();
          } else {
            unawaited(c.stop());
          }
        });
        await c.open();
        expect(revoked, true);
        expect(p.opens, 0);
        expect(c.url, isNull);
        expect(c.opening, false);
        if (!disposeDuringOpen) c.dispose();
      },
    );
  }
  test(
    'authority callback Stop prevents browser dispatch and permits fresh retry',
    () async {
      final p = Preview();
      var stopOnAuthority = false;
      late HtmlReviewedPreviewController c;
      c = controller(
        p,
        authorize: () {
          if (stopOnAuthority) {
            stopOnAuthority = false;
            unawaited(c.stop());
          }
        },
      );
      addTearDown(c.dispose);
      p.pending.complete(Uri.parse('http://127.0.0.1:123/token/'));
      await c.confirm();
      stopOnAuthority = true;
      await c.open();
      expect(p.opens, 0);
      expect(c.url, isNull);
      expect(c.locked, false);
      p.pending = Completer()
        ..complete(Uri.parse('http://127.0.0.1:123/retry/'));
      await c.confirm();
      await c.open();
      expect(p.opens, 1);
      expect(c.opening, false);
    },
  );
  testWidgets('browser deadline retains launch ownership until settlement', (
    tester,
  ) async {
    final p = Preview()..pendingOpen = Completer<void>();
    final c = controller(p, deadline: const Duration(seconds: 1));
    p.pending.complete(Uri.parse('http://127.0.0.1:123/token/'));
    await c.confirm();
    await tester.pumpWidget(
      MaterialApp(home: HtmlReviewedPreviewScreen(controller: c)),
    );
    final launch = c.open();
    await tester.pump(const Duration(seconds: 2));
    expect(c.error, contains('Browser launch deadline reached'));
    expect(c.url, isNull);
    expect(c.opening, true);
    expect(c.locked, true);
    expect(() => p.authority!(), throwsStateError);
    await c.confirm();
    await c.open();
    expect(p.starts, 1);
    expect(p.opens, 1);
    expect(find.text('Stop passive preview'), findsOneWidget);
    p.pendingOpen!.complete();
    await launch;
    await tester.pump();
    expect(c.error, contains('launch request has returned'));
    expect(c.url, isNull);
    expect(c.locked, false);
    p.pending = Completer()..complete(Uri.parse('http://127.0.0.1:123/retry/'));
    p.pendingOpen = null;
    await c.confirm();
    await c.open();
    expect(p.opens, 2);
    await tester.pump(const Duration(seconds: 2));
    expect(c.url, isNotNull);
    expect(c.error, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'failed browser launch disarms deadline and preserves cleanup retry',
    (tester) async {
      final p = Preview()
        ..pendingOpen = Completer<void>()
        ..failStop = true;
      final c = controller(p, deadline: const Duration(seconds: 1));
      p.pending.complete(Uri.parse('http://127.0.0.1:123/token/'));
      await c.confirm();
      final launch = c.open();
      p.pendingOpen!.completeError(StateError('private launch failure'));
      await launch;
      expect(c.cleanupFailed, true);
      expect(c.locked, true);
      await tester.pump(const Duration(seconds: 2));
      expect(c.error, contains('cleanup failed'));
      expect(c.error, isNot(contains('private launch failure')));
      expect(c.error, isNot(contains('deadline')));
      p.failStop = false;
      await c.stop();
      expect(c.locked, false);
      c.dispose();
    },
  );
  test('confirmation owns startup, overlap exclusion, open and Stop', () async {
    final p = Preview();
    final c = controller(p);
    expect(p.starts, 0);
    await c.open();
    expect(p.opens, 0);
    final work = c.confirm();
    await c.confirm();
    expect(p.starts, 1);
    p.pending.complete(Uri.parse('http://127.0.0.1:123/token/'));
    await work;
    expect(c.url, isNotNull);
    await c.confirm();
    expect(p.starts, 1);
    await c.open();
    expect(p.opens, 1);
    await c.stop();
    expect(c.url, isNull);
    expect(() => p.authority!(), throwsStateError);
    c.dispose();
  });
  test(
    'Stop retains pending exclusion, ignores late result then permits retry',
    () async {
      final p = Preview();
      final c = controller(p);
      final work = c.confirm();
      await c.stop();
      await c.confirm();
      expect(p.starts, 1);
      expect(c.busy, true);
      p.pending.complete(Uri.parse('http://127.0.0.1:123/late/'));
      await work;
      expect(c.url, isNull);
      expect(c.error, contains('Startup has returned'));
      p.pending = Completer();
      final retry = c.confirm();
      expect(p.starts, 2);
      p.pending.complete(Uri.parse('http://127.0.0.1:123/retry/'));
      await retry;
      expect(c.url, isNotNull);
      c.dispose();
    },
  );
  test('failed Stop blocks redispatch until cleanup retry succeeds', () async {
    final p = Preview();
    final c = controller(p);
    addTearDown(c.dispose);
    p.pending.complete(Uri.parse('http://127.0.0.1:123/token/'));
    await c.confirm();
    p.failStop = true;
    await c.stop();
    expect(c.url, isNull);
    expect(c.locked, true);
    expect(() => p.authority!(), throwsStateError);
    await c.confirm();
    await c.open();
    expect(p.starts, 1);
    expect(p.opens, 0);
    await c.stop();
    expect(c.locked, true);
    p.failStop = false;
    await c.stop();
    expect(c.locked, false);
    p.pending = Completer();
    final retry = c.confirm();
    expect(p.starts, 2);
    p.pending.complete(Uri.parse('http://127.0.0.1:123/retry/'));
    await retry;
    expect(c.url, isNotNull);
  });

  test(
    'startup failure retains failed cleanup until explicit Stop retry',
    () async {
      final p = Preview()..failStop = true;
      final c = controller(p);
      addTearDown(c.dispose);
      final work = c.confirm();
      p.pending.completeError(StateError('startup failed'));
      await work;
      expect(c.busy, false);
      expect(c.locked, true);
      await c.confirm();
      expect(p.starts, 1);
      p.failStop = false;
      await c.stop();
      expect(c.locked, false);
    },
  );

  testWidgets('cleanup failure keeps a visible actionable Stop retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final p = Preview()..failStop = true;
    final c = controller(p);
    final work = c.confirm();
    p.pending.completeError(StateError('startup failed'));
    await work;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: HtmlReviewedPreviewScreen(controller: c),
        ),
      ),
    );
    final retry = find.text('Retry passive preview cleanup');
    await tester.scrollUntilVisible(
      retry,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(retry);
    await tester.pumpAndSettle();
    p.failStop = false;
    await tester.tap(retry);
    await tester.pumpAndSettle();
    expect(c.locked, false);
    expect(find.text('Retry passive preview cleanup'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('deadline ignores late startup and reports settled state', (
    tester,
  ) async {
    final p = Preview();
    final c = controller(p, deadline: const Duration(seconds: 1));
    final work = c.confirm();
    await tester.pump(const Duration(seconds: 1));
    expect(c.error, contains('deadline'));
    expect(c.busy, true);
    await c.confirm();
    expect(p.starts, 1);
    p.pending.complete(Uri.parse('http://127.0.0.1:123/late/'));
    await work;
    expect(c.url, isNull);
    expect(c.error, contains('Startup has returned'));
    c.dispose();
  });
  test(
    'stale authority and disposal refuse late results and opening',
    () async {
      final p = Preview();
      var fresh = true;
      final c = controller(
        p,
        authorize: () {
          if (!fresh) throw StateError('stale');
        },
      );
      final work = c.confirm();
      fresh = false;
      p.pending.complete(Uri.parse('http://127.0.0.1:123/late/'));
      await work;
      expect(c.url, isNull);
      expect(c.error, isNotNull);
      fresh = true;
      p.pending = Completer();
      final next = c.confirm();
      c.dispose();
      p.pending.complete(Uri.parse('http://127.0.0.1:123/late/'));
      await next;
      expect(c.url, isNull);
      expect(p.stops, greaterThanOrEqualTo(2));
    },
  );
  test(
    'startup failure settles before retry and stale open is never launched',
    () async {
      final p = Preview();
      var fresh = true;
      final c = controller(
        p,
        authorize: () {
          if (!fresh) throw StateError('stale');
        },
      );
      final failed = c.confirm();
      p.pending.completeError(StateError('read failed'));
      await failed;
      expect(c.busy, false);
      expect(c.url, isNull);
      expect(c.error, isNotNull);
      p.pending = Completer();
      final retry = c.confirm();
      p.pending.complete(Uri.parse('http://127.0.0.1:123/token/'));
      await retry;
      fresh = false;
      await c.open();
      expect(p.opens, 0);
      expect(c.url, isNull);
      c.dispose();
    },
  );
  testWidgets(
    'export preview retains its owner through theme changes and resize',
    (tester) async {
      final c = HtmlReviewedExportController(
        proposal: source(),
        authorizeSource: () {},
        exporter: fixtures.Export(),
        picker: fixtures.Picker(),
      );
      await c.pickParent();
      c.editFolder('site');
      c.prepareReview();
      await c.confirm(c.review!);
      late StateSetter changeTheme;
      var dark = false;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (_, state) {
            changeTheme = state;
            return MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              home: HtmlReviewedExportScreen(controller: c),
            );
          },
        ),
      );
      final link = find.text('Review script-disabled preview');
      await tester.scrollUntilVisible(
        link,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      expect(find.text('Passive reviewed HTML preview'), findsOneWidget);
      expect(find.text('Confirm script-disabled preview'), findsOneWidget);
      final owner = tester
          .widget<HtmlReviewedPreviewScreen>(
            find.byType(HtmlReviewedPreviewScreen),
          )
          .controller;
      changeTheme(() => dark = true);
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpAndSettle();
      expect(
        identical(
          owner,
          tester
              .widget<HtmlReviewedPreviewScreen>(
                find.byType(HtmlReviewedPreviewScreen),
              )
              .controller,
        ),
        true,
      );
      expect(owner.isDisposed, false);
      expect(c.destination, '/exports/site');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(owner.isDisposed, true);
    },
  );
  testWidgets('320px enlarged view confirms only on explicit input', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final p = Preview();
    final c = controller(p);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: HtmlReviewedPreviewScreen(controller: c),
        ),
      ),
    );
    expect(p.starts, 0);
    final button = find.text('Confirm script-disabled preview');
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pump();
    expect(p.starts, 1);
    p.pending.complete(Uri.parse('http://127.0.0.1:123/token/'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Stop passive preview'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Stop passive preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop passive preview'));
    await tester.pumpAndSettle();
    expect(c.url, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
