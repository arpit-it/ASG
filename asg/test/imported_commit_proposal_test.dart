// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_commit_context.dart';
import 'package:asg/models/imported_commit_proposal.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/source_line_diff.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_context_test.dart'
    show commitContext, contextObservationData;

ImportedPlan reviewedCommitPlan(
  ImportedCommitContext context, {
  bool approved = true,
  String text = 'Review exact committed source',
  DateTime? recordedAt,
}) => ImportedPlan(
  text: text,
  context: context.recordJson,
  approved: approved,
  recordedAt: recordedAt ?? DateTime.utc(2026),
);
ImportedCommitProposal commitProposal({
  ImportedCommitContext? context,
  ImportedPlan? plan,
  String path = 'lib/main.dart',
  String replacement = '\ufeff// changed café\r\n// no newline',
}) {
  final captured = context ?? commitContext();
  return ImportedCommitProposal.create(
    context: captured,
    plan: plan ?? reviewedCommitPlan(captured),
    path: path,
    replacement: replacement,
  );
}

void main() {
  test('proposal binds full immutable context and reviewed plan with exact bytes and line tokens', () {
    final context = commitContext(), plan = reviewedCommitPlan(commitContext());
    final value = commitProposal(context: context, plan: plan);
    expect(value.contextDigest, context.digest);
    expect(
      value.planDigest,
      sha256.convert(utf8.encode(jsonEncode(plan.toJson()))).toString(),
    );
    expect(value.source.source.bytes, context.files.first.source.bytes);
    expect(value.source.mode, '100644');
    expect(
      value.afterHash,
      sha256.convert(utf8.encode(value.replacement)).toString(),
    );
    expect(value.afterByteLength, utf8.encode(value.replacement).length);
    final data = jsonDecode(value.recordJson);
    expect(data['commit'], context.commit);
    expect(data['tree'], context.tree);
    expect(data['manifest_sha256'], context.manifestDigest);
    expect(data['before_git_blob'], context.files.first.gitBlob);
    expect(data['before_byte_length'], context.files.first.source.byteLength);
    expect(
      value.diff.lines
          .where((l) => l.kind != SourceLineKind.added)
          .map((l) => l.text)
          .join(),
      context.files.first.source.text,
    );
    expect(
      value.diff.lines
          .where((l) => l.kind != SourceLineKind.removed)
          .map((l) => l.text)
          .join(),
      value.replacement,
    );
    expect(value.sourceVerified, false);
    expect(value.workingTree, 'unknown');
    expect(value.conflict, 'unknown');
    expect(value.recordJson, isNot(contains('command')));
    expect(() => value.diff.lines.clear(), throwsUnsupportedError);
  });
  test('same inputs stable; commit metadata full plan and literal edit alter identity', () {
    final a = commitProposal();
    expect(a.matches(commitProposal()), true);
    final context = commitContext();
    for (final changed in [
      commitProposal(context: commitContext(commit: 'd' * 40)),
      commitProposal(
        context: commitContext(
          data: contextObservationData()..['tree'] = 'e' * 40,
        ),
      ),
      commitProposal(
        context: commitContext(
          data: contextObservationData()..['manifest_sha256'] = 'f' * 64,
        ),
      ),
      commitProposal(
        plan: reviewedCommitPlan(context, text: 'Different reviewed plan'),
      ),
      commitProposal(
        plan: reviewedCommitPlan(context, recordedAt: DateTime.utc(2027)),
      ),
      commitProposal(path: 'test/peer.dart'),
      commitProposal(replacement: '// another changed draft\n'),
    ]) {
      expect(changed.digest, isNot(a.digest));
    }
  });
  test('unapproved or mismatched plan and unselected or no-op replacement refuse privately', () {
    final context = commitContext();
    for (final create in <ImportedCommitProposal Function()>[
      () => commitProposal(plan: reviewedCommitPlan(context, approved: false)),
      () => commitProposal(
        plan: reviewedCommitPlan(commitContext(commit: 'd' * 40)),
      ),
      () => commitProposal(path: '../outside.dart'),
      () => commitProposal(path: 'lib/not-selected.dart'),
      () => commitProposal(replacement: context.files.first.source.text),
      () => commitProposal(plan: reviewedCommitPlan(context, text: '\ud800')),
      () => commitProposal(replacement: '\udfff'),
      () => commitProposal(replacement: 'bad\u0000data'),
    ]) {
      expect(
        create,
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Committed source proposal inputs are invalid or exceed local preview limits.',
          ),
        ),
      );
    }
  });
  test('before and replacement byte and line limits refuse without truncating context', () {
    final large = commitContext(
      data: contextObservationData(text: 'x' * 30000),
    );
    expect(large.files.first.source.byteLength, 30000);
    expect(() => commitProposal(context: large), throwsFormatException);
    expect(large.files.first.source.byteLength, 30000);
    expect(
      () => commitProposal(replacement: 'x' * 16385),
      throwsFormatException,
    );
    expect(
      () => commitProposal(replacement: 'a\n' * 501),
      throwsFormatException,
    );
    expect(commitProposal(replacement: 'x' * 16384).afterByteLength, 16384);
  });
  test('empty selected file is a valid before value and coarse diff retains exact text', () {
    final empty = commitProposal(path: 'test/peer.dart');
    expect(empty.source.source.byteLength, 0);
    expect(empty.diff.lines.every((l) => l.kind == SourceLineKind.added), true);
    final context = commitContext(
      data: contextObservationData(
        text: '${List.generate(300, (i) => 'old$i').join('\n')}\n',
      ),
    );
    final replacement =
        '${List.generate(300, (i) => 'new$i').join('\r\n')}\r\n';
    final coarse = commitProposal(context: context, replacement: replacement);
    expect(coarse.diff.coarse, true);
    expect(
      coarse.diff.lines
          .where((l) => l.kind != SourceLineKind.added)
          .map((l) => l.text)
          .join(),
      context.files.first.source.text,
    );
    expect(
      coarse.diff.lines
          .where((l) => l.kind != SourceLineKind.removed)
          .map((l) => l.text)
          .join(),
      replacement,
    );
  });
}
