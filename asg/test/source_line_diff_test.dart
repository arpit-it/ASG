// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:math';

import 'package:asg/models/source_line_diff.dart';
import 'package:asg/views/source_diff_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void assertRoundTrip(String before, String after, SourceLineDiff diff) {
  expect(
    diff.lines
        .where((r) => r.kind != SourceLineKind.added)
        .map((r) => r.text)
        .join(),
    before,
  );
  expect(
    diff.lines
        .where((r) => r.kind != SourceLineKind.removed)
        .map((r) => r.text)
        .join(),
    after,
  );
  var old = 0, next = 0;
  for (final row in diff.lines) {
    expect(row.beforeLine, row.kind == SourceLineKind.added ? null : ++old);
    expect(row.afterLine, row.kind == SourceLineKind.removed ? null : ++next);
  }
}

void main() {
  test(
    'line numbers distinguish inserts, deletions and replacement context',
    () {
      final diff = SourceLineDiff.compare('a\nb\nc\n', 'a\nx\nc\ny\n');
      expect(
        diff.display,
        '  1 1 | a [LF]\n- 2 · | b [LF]\n+ · 2 | x [LF]\n  3 3 | c [LF]\n+ · 4 | y [LF]',
      );
      expect(diff.coarse, isFalse);
      assertRoundTrip('a\nb\nc\n', 'a\nx\nc\ny\n', diff);
      expect(() => diff.lines.clear(), throwsUnsupportedError);
    },
  );

  test(
    'line endings, blank lines, Unicode and missing final newline stay exact',
    () {
      for (final pair in [
        ['', ''],
        ['', '\n'],
        ['\n', ''],
        ['hello\n', 'hello'],
        ['hello\r\n', 'hello\n'],
        ['a\rb\r', 'a\nb\n'],
        ['\r\n\r\n', '\n\n'],
        ['🧪 café\t\n', '🧪 हिंदी\t'],
        ['a\na\nb\na\n', 'a\nb\na\na\n'],
      ]) {
        final diff = SourceLineDiff.compare(pair[0], pair[1]);
        assertRoundTrip(pair[0], pair[1], diff);
      }
      final endings = SourceLineDiff.compare('a\r\nb\rc\n', 'a\r\nb\rc');
      expect(endings.display, contains('[CRLF]'));
      expect(endings.display, contains('[CR]'));
      expect(endings.display, contains('[LF]'));
      expect(endings.display, contains('[no newline]'));
    },
  );

  test(
    'adversarial repeated lines reconstruct both inputs deterministically',
    () {
      final random = Random(42);
      const tokens = ['same\n', 'other\r\n', '\r', '🧪\n', '\n'];
      for (var iteration = 0; iteration < 200; iteration++) {
        String sample() => List.generate(
          random.nextInt(35),
          (_) => tokens[random.nextInt(tokens.length)],
        ).join();
        final before = sample(), after = sample();
        final diff = SourceLineDiff.compare(before, after);
        assertRoundTrip(before, after, diff);
        expect(SourceLineDiff.compare(before, after).display, diff.display);
      }
    },
  );

  test(
    'matrix bound falls back truthfully; long matching edges remain context',
    () {
      final before = 'head\n${List.filled(300, 'old\n').join()}tail\n';
      final after = 'head\n${List.filled(300, 'new\n').join()}tail\n';
      final diff = SourceLineDiff.compare(before, after);
      expect(diff.coarse, isTrue);
      expect(diff.lines.first.kind, SourceLineKind.context);
      expect(diff.lines.last.kind, SourceLineKind.context);
      assertRoundTrip(before, after, diff);
      final large = List.filled(16000, '\n').join();
      final smallEdit = SourceLineDiff.compare(
        '${large}old\n',
        '${large}new\n',
      );
      expect(smallEdit.coarse, isFalse);
      assertRoundTrip('${large}old\n', '${large}new\n', smallEdit);
      final deletion = SourceLineDiff.compare(large, '');
      expect(deletion.coarse, isFalse);
      assertRoundTrip(large, '', deletion);
    },
  );

  testWidgets('coarse diff and long code wrap at 320px and 200 percent text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final diff = SourceLineDiff.compare(
      List.filled(260, '${List.filled(100, 'x').join()}\n').join(),
      List.filled(260, 'new\n').join(),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(child: SourceDiffView(diff: diff)),
        ),
      ),
    );
    expect(find.text('Line changes'), findsOneWidget);
    expect(find.textContaining('Large comparison:'), findsOneWidget);
    expect(find.text(diff.display), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
