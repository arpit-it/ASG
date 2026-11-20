// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_source_proposal.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/source_line_diff.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_plan_test.dart' show capturedSourcePlan;

void main() {
  test('transient proposal binds exact source and full reviewed plan with literal BOM CRLF diff', () {
    final context = capturedSourcePlan(text: '\ufeffbefore\r\n');
    final plan = ImportedPlan(
      text: 'Manual reviewed proposal',
      context: context.recordJson,
      approved: true,
      recordedAt: DateTime.utc(2026, 11, 20),
    );
    ImportedSourceProposal build({
      String after = '\ufeffafter\r\n',
      ImportedPlan? selected,
    }) => ImportedSourceProposal.create(
      context: context,
      plan: selected ?? plan,
      path: 'lib/main.dart',
      replacement: after,
    );
    final p = build();
    expect(p.sourceVerified, false);
    expect(p.root, '/project');
    expect(p.contextDigest, context.digest);
    expect(
      p.planDigest,
      sha256.convert(utf8.encode(jsonEncode(plan.toJson()))).toString(),
    );
    expect(p.matches(build()), true);
    expect(
      p.diff.lines
          .where((l) => l.kind != SourceLineKind.added)
          .map((l) => l.text)
          .join(),
      '\ufeffbefore\r\n',
    );
    expect(
      p.diff.lines
          .where((l) => l.kind != SourceLineKind.removed)
          .map((l) => l.text)
          .join(),
      '\ufeffafter\r\n',
    );
    expect(
      p.afterHash,
      sha256.convert(utf8.encode('\ufeffafter\r\n')).toString(),
    );
    expect(p.matches(build(after: 'after\n')), false);
    expect(
      p.matches(
        build(
          selected: ImportedPlan(
            text: plan.text,
            context: plan.context,
            approved: true,
            recordedAt: DateTime.utc(2026, 11, 20, 0, 0, 1),
          ),
        ),
      ),
      false,
    );
    expect(() => p.diff.lines.clear(), throwsUnsupportedError);
    expect(() => p.source.bytes.clear(), throwsUnsupportedError);
  });
  test(
    'unapproved mismatched unselected and unchanged proposals refuse privately',
    () {
      final c = capturedSourcePlan();
      final good = ImportedPlan(
        text: 'Manual proposal',
        context: c.recordJson,
        approved: true,
        recordedAt: DateTime.utc(2026),
      );
      for (final action in [
        () => ImportedSourceProposal.create(
          context: c,
          plan: ImportedPlan(
            text: good.text,
            context: good.context,
            approved: false,
            recordedAt: good.recordedAt,
          ),
          path: 'lib/main.dart',
          replacement: 'changed',
        ),
        () => ImportedSourceProposal.create(
          context: c,
          plan: ImportedPlan(
            text: good.text,
            context: 'private-wrong-context',
            approved: true,
            recordedAt: good.recordedAt,
          ),
          path: 'lib/main.dart',
          replacement: 'changed',
        ),
        () => ImportedSourceProposal.create(
          context: c,
          plan: good,
          path: 'asg/lib/main.dart',
          replacement: 'changed',
        ),
        () => ImportedSourceProposal.create(
          context: c,
          plan: good,
          path: 'test/not_selected.dart',
          replacement: 'changed',
        ),
        () => ImportedSourceProposal.create(
          context: c,
          plan: good,
          path: 'lib/main.dart',
          replacement: c.files.single.text,
        ),
      ]) {
        expect(
          action,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'private error',
              'Imported source proposal inputs are invalid or exceed local preview limits.',
            ),
          ),
        );
      }
    },
  );
  test('text admission preserves BOM and byte distinctions and refuses invalid or oversized inputs', () {
    expect(ImportedSourceProposal.validText('\ufeffcafé\r\n'), true);
    expect(ImportedSourceProposal.validText('x' * 16384), true);
    expect(ImportedSourceProposal.validText('x' * 16385), false);
    expect(ImportedSourceProposal.validText('é' * 8192), true);
    expect(ImportedSourceProposal.validText('é' * 8193), false);
    expect(
      ImportedSourceProposal.validText(List.filled(500, 'x').join('\n')),
      true,
    );
    expect(
      ImportedSourceProposal.validText(List.filled(501, 'x').join('\n')),
      false,
    );
    for (final value in ['\ud800', 'a\u0000b', 'a\u001bb', 'a\u007fb']) {
      expect(ImportedSourceProposal.validText(value), false);
    }
  });
  test('empty replacement is proposed empty contents only; record carries no execution transport', () {
    final c = capturedSourcePlan();
    final p = ImportedSourceProposal.create(
      context: c,
      plan: ImportedPlan(
        text: 'Manual proposal',
        context: c.recordJson,
        approved: true,
        recordedAt: DateTime.utc(2026),
      ),
      path: 'lib/main.dart',
      replacement: '',
    );
    final data = jsonDecode(p.recordJson) as Map;
    expect(p.replacement, '');
    expect(p.afterHash, sha256.convert([]).toString());
    expect(data.keys.toSet(), {
      'version',
      'scope',
      'source_verified',
      'root',
      'context_sha256',
      'plan_sha256',
      'path',
      'before_sha256',
      'after_sha256',
      'replacement',
    });
    expect(
      utf8.encode(p.recordJson).length,
      lessThanOrEqualTo(ImportedSourceProposal.recordByteLimit),
    );
  });
}
