// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/candidate_proposal_controller.dart';
import 'package:asg/models/candidate_source_proposal.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/views/candidate_proposal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const header =
    '// SPDX-License-Identifier: MPL-2.0\n// Copyright 2026 Arpit Sinha\n\n';
const before = '${header}void main() {}\n';
const after = '${header}void main() { print("proposal"); }\n';
const file = 'asg/lib/main.dart';
final digest = 'a' * 64;
CandidateSourceFile source() => CandidateSourceFile.decode(
  jsonEncode({
    'schemaVersion': 1,
    'digest': digest,
    'path': file,
    'before': before,
    'beforeHash': candidateTextHash(before),
  }),
);
CandidateProposalResult result(
  CandidateSourceProposal proposal,
) => CandidateProposalResult.decode(
  jsonEncode({
    'schemaVersion': 1,
    'path':
        '/destination/${proposal.runName}/${proposal.snapshot.split('/').last}',
    'digest': 'b' * 64,
    'sourceDigest': proposal.source.digest,
    'file': file,
    'afterHash': proposal.afterHash,
  }),
);

class Picker extends FolderPicker {
  @override
  Future<String?> pick() async => '/destination';
}

void main() {
  test('proposal validates exact bytes and legal prefix', () {
    CandidateSourceProposal create(String text) =>
        CandidateSourceProposal.create(
          snapshot: '/snapshot',
          python: '/python',
          trustedSource: '/trusted',
          source: source(),
          replacement: text,
          destination: '/destination',
          runName: 'asg-self-candidate-1234abcd',
        );
    final p = create(after);
    expect(p.payload['expectedDigest'], digest);
    expect(p.afterHash, candidateTextHash(after));
    for (final text in [
      before,
      'void main() {}',
      '',
      '$header${'é' * 9000}',
      '$header${'x\n' * 501}',
      '$header\u0000',
    ]) {
      expect(() => create(text), throwsFormatException);
    }
    expect(isCandidateSourcePath('asg/tools/run.dart'), isFalse);
    expect(isCandidateSourcePath('asg/lib/../main.dart'), isFalse);
    expect(
      () => CandidateSourceFile.decode(
        jsonEncode({
          'schemaVersion': 1.0,
          'digest': digest,
          'path': file,
          'before': before,
          'beforeHash': candidateTextHash(before),
        }),
      ),
      throwsFormatException,
    );
  });
  test('writes require current consent and old result clears', () async {
    var writes = 0;
    var fail = false;
    final c = CandidateProposalController(
      snapshot: '/snapshot',
      python: '/python',
      trustedSource: '/trusted',
      read: ({
        required snapshot,
        required file,
        required python,
        required stop,
        required stopped,
      }) async => source(),
      canonicalize: (v) async => v,
      apply: ({required proposal, required stop, required stopped}) async {
        writes++;
        if (fail) throw StateError('fixture');
        return result(proposal);
      },
    );
    addTearDown(c.dispose);
    await c.load(file);
    final p = (await c.review(
      replacement: after,
      destination: '/destination',
    ))!;
    await c.apply(p, approved: false);
    expect(writes, 0);
    await c.apply(p, approved: true);
    expect(writes, 1);
    expect(c.result, isNotNull);
    await c.apply(p, approved: true);
    expect(writes, 1);
    c.invalidate();
    expect(c.result, isNull);
    await c.load(file);
    final old = (await c.review(
      replacement: after,
      destination: '/destination',
    ))!;
    c.invalidate();
    await c.apply(old, approved: true);
    expect(writes, 1);
    final fresh = (await c.review(
      replacement: after,
      destination: '/destination',
    ))!;
    fail = true;
    await c.apply(fresh, approved: true);
    expect(c.result, isNull);
    expect(c.status, contains('Inspect the destination'));
  });
  test('Stop and disposal suppress late read and apply results', () async {
    for (final dispose in [false, true]) {
      final pending = Completer<CandidateSourceFile>();
      final c = CandidateProposalController(
        snapshot: '/snapshot',
        python: '/python',
        read: ({
          required snapshot,
          required file,
          required python,
          required stop,
          required stopped,
        }) => pending.future,
      );
      final op = c.load(file);
      if (dispose) {
        c.dispose();
      } else {
        c.stop();
      }
      pending.complete(source());
      await op;
      expect(c.source, isNull);
      if (!dispose) c.dispose();
    }
    final pending = Completer<CandidateProposalResult>();
    final c = CandidateProposalController(
      snapshot: '/snapshot',
      python: '/python',
      read: ({
        required snapshot,
        required file,
        required python,
        required stop,
        required stopped,
      }) async => source(),
      canonicalize: (v) async => v,
      apply: ({required proposal, required stop, required stopped}) =>
          pending.future,
    );
    addTearDown(c.dispose);
    await c.load(file);
    final p = (await c.review(
      replacement: after,
      destination: '/destination',
    ))!;
    final op = c.apply(p, approved: true);
    c.stop();
    pending.complete(result(p));
    await op;
    expect(c.result, isNull);
    expect(c.status, contains('unverified output'));
  });
  test('changed inputs revoke pending destination review', () async {
    final pending = Completer<String>();
    final c = CandidateProposalController(
      snapshot: '/snapshot',
      python: '/python',
      read: ({
        required snapshot,
        required file,
        required python,
        required stop,
        required stopped,
      }) async => source(),
      canonicalize: (_) => pending.future,
    );
    addTearDown(c.dispose);
    await c.load(file);
    final op = c.review(replacement: after, destination: '/destination');
    c.invalidate();
    pending.complete('/destination');
    expect(await op, isNull);
  });
  testWidgets('narrow explicit review Cancel makes no write', (tester) async {
    tester.view.physicalSize = const Size(320, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var writes = 0;
    final c = CandidateProposalController(
      snapshot: '/snapshot',
      python: '/python',
      read: ({
        required snapshot,
        required file,
        required python,
        required stop,
        required stopped,
      }) async => source(),
      canonicalize: (v) async => v,
      apply: ({required proposal, required stop, required stopped}) async {
        writes++;
        return result(proposal);
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: CandidateProposalScreen(controller: c, picker: Picker()),
      ),
    );
    await tester.tap(find.text('Read candidate source'));
    await tester.pumpAndSettle();
    final editor = find.widgetWithText(
      TextField,
      'Complete replacement (16 KiB, 500 lines maximum)',
    );
    await tester.scrollUntilVisible(
      editor,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(editor, after);
    final choose = find.text('Choose new snapshot destination');
    await tester.scrollUntilVisible(
      choose,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(choose);
    await tester.pumpAndSettle();
    final review = find.text('Review replacement and destination');
    await tester.scrollUntilVisible(
      review,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(find.text('Create a new unverified snapshot?'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(writes, 0);
    await tester.tap(review);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create new snapshot'));
    await tester.pumpAndSettle();
    expect(writes, 1);
    expect(c.result, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
