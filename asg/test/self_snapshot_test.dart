// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/models/self_snapshot_operation.dart';
import 'package:asg/models/snapshot_preparation_failure.dart';
import 'package:asg/models/snapshot_recovery_inventory.dart';
import 'package:asg/models/candidate_comparison.dart';
import 'package:asg/models/candidate_file_review.dart';
import 'package:asg/views/candidate_file_review_dialog.dart';
import 'package:asg/controllers/self_snapshot_controller.dart';
import 'package:asg/models/generation_command_result.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/views/self_snapshot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FixturePicker extends FolderPicker {
  FixturePicker([List<String> paths = const ['/source', '/destination']])
    : folders = paths.iterator;

  final Iterator<String> folders;

  @override
  Future<String?> pick() async => folders.moveNext() ? folders.current : null;
}

void main() {
  final commitId = 'a' * 40;

  CandidateComparison comparison(String digest, String commit) =>
      CandidateComparison.decode(
        jsonEncode({
          'schemaVersion': 1,
          'commit': commit,
          'digest': digest,
          'counts': {
            'added': 1,
            'modified': 1,
            'removed': 0,
            'executableChanged': 1,
          },
          'changes': [
            {'path': 'added.dart', 'kind': 'added', 'executableChanged': false},
            {
              'path': 'changed.dart',
              'kind': 'modified',
              'executableChanged': true,
            },
          ],
          'truncated': false,
        }),
      );

  Map<String, Object?> filePayload({
    String path = 'changed.dart',
    String? before = 'before',
    String? after = 'after',
  }) => {
    'schemaVersion': 1,
    'commit': commitId,
    'digest': 'a' * 64,
    'path': path,
    'before': {'state': before == null ? 'absent' : 'text', 'text': before},
    'after': {'state': after == null ? 'absent' : 'text', 'text': after},
  };

  test(
    'file content protocol enforces complete UTF8 sides and schema bounds',
    () {
      final valid = filePayload();
      expect(
        CandidateFileReview.decode(jsonEncode(valid)).before.text,
        'before',
      );
      expect(
        CandidateFileReview.decode(jsonEncode(filePayload(before: 'é' * 8192)))
            .before
            .text!
            .length,
        8192,
      );
      expect(
        CandidateFileReview.decode(
          jsonEncode(filePayload(before: 'x\r\n' * 500)),
        ).before.state,
        CandidateTextState.text,
      );
      expect(
        CandidateFileReview.decode(
          jsonEncode(filePayload(before: '', after: null)),
        ).before.text,
        '',
      );
      for (final altered in [
        {...valid, 'schemaVersion': 1.0},
        {...valid, 'path': '../outside'},
        {...valid, 'digest': 'wrong'},
        {...valid, 'unknown': true},
        filePayload(before: null, after: null),
        filePayload(before: 'é' * 8193),
        filePayload(before: 'x\r' * 501),
        filePayload(before: 'x\u2028' * 501),
        filePayload(before: '\u0000'),
        filePayload(before: '\u0080'),
        filePayload(before: String.fromCharCode(0xd800)),
        {
          ...valid,
          'before': {'state': 'unsupported', 'text': 'hidden'},
        },
      ]) {
        expect(
          () => CandidateFileReview.decode(jsonEncode(altered)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'file inspection binds selection and revokes malformed or failed reviews',
    () async {
      var reads = 0;
      var invalid = false;
      var fail = false;
      var scans = 0;
      final controller = SelfSnapshotController(
        compare: ({
          required snapshot,
          required source,
          required commit,
          required python,
          required stop,
          required stopped,
        }) async => comparison('a' * 64, commitId),
        fingerprint:
            ({
              required snapshot,
              required python,
              required stop,
              required stopped,
            }) async {
              scans++;
              return 'a' * 64;
            },
        readFile:
            ({
              required snapshot,
              required source,
              required commit,
              required digest,
              required file,
              required python,
              required stop,
              required stopped,
            }) async {
              reads++;
              if (fail) throw StateError('fixture');
              expect(
                (source, commit, digest, file),
                ('/repo', commitId, 'a' * 64, 'changed.dart'),
              );
              return CandidateFileReview.decode(
                jsonEncode(filePayload(before: invalid ? null : 'before')),
              );
            },
      );
      addTearDown(controller.dispose);
      Future<CandidateReview> fresh() async =>
          (await controller.reviewCandidate(
            snapshot: '/snapshot',
            python: '/python',
            source: '/repo',
            commit: commitId,
          ))!;
      final first = await fresh();
      expect(
        await controller.inspectCandidateFile(first, 'not-listed'),
        isNull,
      );
      expect(reads, 0);
      expect(controller.isCurrentReview(first), isFalse);
      final review = await fresh();
      expect(
        (await controller.inspectCandidateFile(
          review,
          'changed.dart',
        ))?.after.text,
        'after',
      );
      expect(controller.isCurrentReview(review), isTrue);
      invalid = true;
      expect(
        await controller.inspectCandidateFile(review, 'changed.dart'),
        isNull,
      );
      await controller.approveCandidate(review);
      expect(scans, 0);
      invalid = false;
      fail = true;
      final retry = await fresh();
      expect(
        await controller.inspectCandidateFile(retry, 'changed.dart'),
        isNull,
      );
      expect(controller.isCurrentReview(retry), isFalse);
    },
  );

  test('Stop input invalidation and disposal suppress pending file contents and approval', () async {
    for (final action in ['stop', 'inputs', 'dispose']) {
      final pending = Completer<CandidateFileReview>();
      var scans = 0;
      final controller = SelfSnapshotController(
        compare: ({
          required snapshot,
          required source,
          required commit,
          required python,
          required stop,
          required stopped,
        }) async => comparison('a' * 64, commitId),
        fingerprint:
            ({
              required snapshot,
              required python,
              required stop,
              required stopped,
            }) async {
              scans++;
              return 'a' * 64;
            },
        readFile: ({
          required snapshot,
          required source,
          required commit,
          required digest,
          required file,
          required python,
          required stop,
          required stopped,
        }) => pending.future,
      );
      final review = (await controller.reviewCandidate(
        snapshot: '/snapshot',
        python: '/python',
        source: '/repo',
        commit: commitId,
      ))!;
      final read = controller.inspectCandidateFile(review, 'changed.dart');
      if (action == 'stop') controller.stop();
      if (action == 'inputs') controller.clearStatus();
      if (action == 'dispose') controller.dispose();
      pending.complete(CandidateFileReview.decode(jsonEncode(filePayload())));
      expect(await read, isNull);
      await controller.approveCandidate(review);
      expect(scans, 0);
      expect(controller.isCurrentReview(review), isFalse);
      if (action != 'dispose') controller.dispose();
    }
  });

  testWidgets(
    'narrow file review displays plain before and after with selectable text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = SelfSnapshotController(
        compare: ({
          required snapshot,
          required source,
          required commit,
          required python,
          required stop,
          required stopped,
        }) async => comparison('a' * 64, commitId),
        readFile:
            ({
              required snapshot,
              required source,
              required commit,
              required digest,
              required file,
              required python,
              required stop,
              required stopped,
            }) async => CandidateFileReview.decode(
              jsonEncode(
                filePayload(
                  before: '<script>old</script>',
                  after: '<script>new</script>',
                ),
              ),
            ),
      );
      addTearDown(controller.dispose);
      final review = (await controller.reviewCandidate(
        snapshot: '/snapshot',
        python: '/python',
        source: '/repo',
        commit: commitId,
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => CandidateFileReviewDialog(
                  controller: controller,
                  review: review,
                  summary: 'Selected baseline comparison',
                ),
              ),
              child: const Text('Open review'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open review'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(DropdownButtonFormField<String>),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('changed.dart').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Inspect before and after'));
      await tester.tap(find.text('Inspect before and after'));
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == '<script>old</script>',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == '<script>new</script>',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      controller.clearStatus();
      await tester.pumpAndSettle();
      expect(
        find.text('Review invalidated. Close and create a fresh comparison.'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) => w is SelectableText && w.data == '<script>new</script>',
        ),
        findsNothing,
      );
    },
  );

  test(
    'file review mismatched commit digest or path revokes the handle',
    () async {
      for (final field in ['commit', 'digest', 'path']) {
        final controller = SelfSnapshotController(
          compare: ({
            required snapshot,
            required source,
            required commit,
            required python,
            required stop,
            required stopped,
          }) async => comparison('a' * 64, commitId),
          readFile:
              ({
                required snapshot,
                required source,
                required commit,
                required digest,
                required file,
                required python,
                required stop,
                required stopped,
              }) async {
                final payload = filePayload();
                payload[field] = field == 'commit'
                    ? 'b' * 40
                    : field == 'digest'
                    ? 'b' * 64
                    : 'other.dart';
                return CandidateFileReview.decode(jsonEncode(payload));
              },
        );
        final review = (await controller.reviewCandidate(
          snapshot: '/snapshot',
          python: '/python',
          source: '/repo',
          commit: commitId,
        ))!;
        expect(
          await controller.inspectCandidateFile(review, 'changed.dart'),
          isNull,
        );
        expect(controller.isCurrentReview(review), isFalse);
        controller.dispose();
      }
    },
  );

  testWidgets(
    'closing a pending file dialog stops work and cannot restore approval',
    (tester) async {
      final pending = Completer<CandidateFileReview>();
      final controller = SelfSnapshotController(
        compare: ({
          required snapshot,
          required source,
          required commit,
          required python,
          required stop,
          required stopped,
        }) async => comparison('a' * 64, commitId),
        readFile:
            ({
              required snapshot,
              required source,
              required commit,
              required digest,
              required file,
              required python,
              required stop,
              required stopped,
            }) {
              return pending.future;
            },
      );
      addTearDown(controller.dispose);
      final review = (await controller.reviewCandidate(
        snapshot: '/snapshot',
        python: '/python',
        source: '/repo',
        commit: commitId,
      ))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                builder: (_) => CandidateFileReviewDialog(
                  controller: controller,
                  review: review,
                  summary: 'Selected comparison',
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('changed.dart').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inspect before and after'));
      await tester.pump();
      expect(controller.busy, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Approve candidate'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.isCurrentReview(review), isFalse);
      expect(controller.stopping, isTrue);
      pending.complete(CandidateFileReview.decode(jsonEncode(filePayload())));
      await tester.pumpAndSettle();
      expect(controller.busy, isFalse);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test('comparison transport refuses malformed and inconsistent evidence', () {
    final valid = {
      'schemaVersion': 1,
      'commit': commitId,
      'digest': 'a' * 64,
      'counts': {
        'added': 0,
        'modified': 0,
        'removed': 0,
        'executableChanged': 0,
      },
      'changes': <Object>[],
      'truncated': false,
    };
    expect(CandidateComparison.decode(jsonEncode(valid)).changes, isEmpty);
    for (final altered in [
      {...valid, 'schemaVersion': 1.0},
      {...valid, 'commit': 'HEAD'},
      {...valid, 'digest': 'wrong'},
      {...valid, 'unknown': 1},
      {...valid, 'truncated': true},
      {
        ...valid,
        'counts': {
          'added': 0,
          'modified': 0,
          'removed': 0,
          'executableChanged': 1,
        },
      },
      {
        ...valid,
        'changes': [
          {'path': '../escape', 'kind': 'added', 'executableChanged': false},
        ],
      },
    ]) {
      expect(
        () => CandidateComparison.decode(jsonEncode(altered)),
        throwsFormatException,
      );
    }
    expect(
      () => comparison('a' * 64, commitId).changes.clear(),
      throwsUnsupportedError,
    );
  });

  test('comparison requires selected baseline and loses late authority after Stop or input invalidation', () async {
    for (final action in ['stop', 'inputs', 'dispose']) {
      final pending = Completer<CandidateComparison>();
      var compares = 0;
      final controller = SelfSnapshotController(
        compare:
            ({
              required snapshot,
              required source,
              required commit,
              required python,
              required stop,
              required stopped,
            }) {
              compares++;
              return pending.future;
            },
      );
      expect(
        await controller.reviewCandidate(
          snapshot: '/snapshot',
          python: '/python',
          source: '',
          commit: commitId,
        ),
        isNull,
      );
      expect(compares, 0);
      final review = controller.reviewCandidate(
        snapshot: '/snapshot',
        python: '/python',
        source: '/repo',
        commit: commitId,
      );
      if (action == 'stop') controller.stop();
      if (action == 'inputs') controller.clearStatus();
      if (action == 'dispose') controller.dispose();
      pending.complete(comparison('a' * 64, commitId));
      expect(await review, isNull);
      if (action != 'dispose') controller.dispose();
    }
  });

  test(
    'comparison baseline mismatch fails and fresh inputs revoke approval',
    () async {
      var selected = 'b' * 40;
      var scans = 0;
      final controller = SelfSnapshotController(
        compare: ({
          required snapshot,
          required source,
          required commit,
          required python,
          required stop,
          required stopped,
        }) async => comparison('a' * 64, selected),
        fingerprint:
            ({
              required snapshot,
              required python,
              required stop,
              required stopped,
            }) async {
              scans++;
              return 'a' * 64;
            },
      );
      addTearDown(controller.dispose);
      Future<CandidateReview?> read() => controller.reviewCandidate(
        snapshot: '/snapshot',
        python: '/python',
        source: '/repo',
        commit: commitId,
      );
      expect(await read(), isNull);
      expect(controller.status, contains('differs'));
      selected = commitId;
      final review = await read();
      expect(review?.comparison?.commit, commitId);
      controller.clearStatus();
      await controller.approveCandidate(review!);
      expect(scans, 0);
    },
  );

  Future<void> runChecks(
    SelfSnapshotController controller, {
    bool approved = true,
    bool buildWeb = false,
  }) => controller.check(
    approved: approved,
    buildWeb: buildWeb,
    snapshot: '/snapshot',
    sdk: '/sdk',
    python: '/python',
  );

  for (final failed in SelfSnapshotOperation.values) {
    test(
      '${failed.name} failure exposes diagnostics until a fresh retry',
      () async {
        var fail = true;
        final calls = <SelfSnapshotOperation>[];
        final controller = SelfSnapshotController(
          check:
              ({
                required snapshot,
                required sdk,
                required python,
                required operation,
                required stop,
                required stopped,
              }) async {
                calls.add(operation);
                return GenerationCommandResult(
                  exitCode: fail && operation == failed ? 1 : 0,
                  output: fail && operation == failed
                      ? 'lib/main.dart:3:7: invalid_assignment'
                      : 'successful tool output',
                );
              },
        );
        addTearDown(controller.dispose);
        final buildWeb = failed == SelfSnapshotOperation.build;
        await runChecks(controller, approved: false, buildWeb: buildWeb);
        expect(calls, isEmpty);
        expect(controller.checkOutput, isNull);
        await runChecks(controller, buildWeb: buildWeb);
        expect(controller.status, contains('${failed.label} failed (exit 1)'));
        expect(
          controller.checkOutput,
          '${failed.label} tool output:\nlib/main.dart:3:7: invalid_assignment',
        );
        if (failed == SelfSnapshotOperation.resolve) {
          expect(calls, [SelfSnapshotOperation.resolve]);
        }
        fail = false;
        await runChecks(controller, buildWeb: buildWeb);
        expect(controller.status, contains('passed'));
        expect(controller.checkOutput, isNull);
      },
    );
  }

  test(
    'timeout and output-limit diagnostics retain their failure status',
    () async {
      for (final timedOut in [true, false]) {
        final controller = SelfSnapshotController(
          check:
              ({
                required snapshot,
                required sdk,
                required python,
                required operation,
                required stop,
                required stopped,
              }) async => GenerationCommandResult(
                exitCode: 0,
                output: '${'x' * 20000}discarded tail',
                timedOut: timedOut,
                outputLimitExceeded: !timedOut,
              ),
        );
        await runChecks(controller);
        expect(
          controller.status,
          contains(timedOut ? 'timed out' : 'exceeded the output limit'),
        );
        expect(controller.checkOutput, contains('[Output truncated'));
        expect(controller.checkOutput, isNot(contains('discarded tail')));
        expect(controller.checkOutput!.length, lessThan(17000));
        controller.dispose();
      }
    },
  );

  test('a new failed dispatch cannot retain an earlier diagnostic', () async {
    final pending = Completer<GenerationCommandResult>();
    var calls = 0;
    final controller = SelfSnapshotController(
      check:
          ({
            required snapshot,
            required sdk,
            required python,
            required operation,
            required stop,
            required stopped,
          }) {
            if (++calls == 1) {
              return Future.value(
                const GenerationCommandResult(
                  exitCode: 1,
                  output: 'old output',
                ),
              );
            }
            return pending.future;
          },
    );
    addTearDown(controller.dispose);
    await runChecks(controller);
    expect(controller.checkOutput, contains('old output'));
    final retry = runChecks(controller);
    expect(controller.checkOutput, isNull);
    pending.completeError(StateError('private transport detail'));
    await retry;
    expect(controller.checkOutput, isNull);
    expect(controller.status, contains('Check unavailable'));
    expect(controller.status, isNot(contains('private transport detail')));
  });

  test(
    'missing diagnostic output is explicit and cancelled output is hidden',
    () async {
      var cancelled = false;
      final controller = SelfSnapshotController(
        check:
            ({
              required snapshot,
              required sdk,
              required python,
              required operation,
              required stop,
              required stopped,
            }) async => GenerationCommandResult(
              exitCode: 1,
              output: cancelled ? 'late cancelled diagnostic' : '',
              cancelled: cancelled,
            ),
      );
      addTearDown(controller.dispose);
      await runChecks(controller);
      expect(
        controller.checkOutput,
        contains('No diagnostic output was captured.'),
      );
      cancelled = true;
      await runChecks(controller);
      expect(controller.checkOutput, isNull);
      expect(controller.status, contains('stopped'));
    },
  );

  test('Stop and disposal suppress late failed-check diagnostics', () async {
    for (final dispose in [false, true]) {
      final result = Completer<GenerationCommandResult>();
      var updates = 0;
      final controller = SelfSnapshotController(
        check: ({
          required snapshot,
          required sdk,
          required python,
          required operation,
          required stop,
          required stopped,
        }) => result.future,
      )..addListener(() => updates++);
      final pending = runChecks(controller);
      if (dispose) {
        controller.dispose();
      } else {
        controller.stop();
      }
      final beforeCompletion = updates;
      result.complete(
        const GenerationCommandResult(exitCode: 1, output: 'late output'),
      );
      await pending;
      expect(controller.checkOutput, isNull);
      if (dispose) {
        expect(updates, beforeCompletion);
      } else {
        expect(controller.status, 'Snapshot checks stopped.');
        controller.dispose();
      }
    }
  });

  testWidgets(
    'approved failure output is selectable and input changes clear it',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      final controller = SelfSnapshotController(
        check:
            ({
              required snapshot,
              required sdk,
              required python,
              required operation,
              required stop,
              required stopped,
            }) async {
              calls++;
              return const GenerationCommandResult(
                exitCode: 1,
                output: '<b>invalid_assignment</b>',
              );
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SelfSnapshotScreen(
            controller: controller,
            picker: FixturePicker(),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).at(1), '/python');
      final pick = find.text('Choose prepared snapshot for checks');
      await tester.ensureVisible(pick);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      final sdk = find.widgetWithText(TextField, 'Flutter SDK folder');
      await tester.scrollUntilVisible(
        sdk,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(sdk, '/sdk');
      final review = find.text('Review offline checks');
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 0);
      expect(find.text('Failed check tool output'), findsNothing);
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve and run'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      final output = find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText &&
            (widget.data?.contains('<b>invalid_assignment</b>') ?? false),
      );
      await tester.ensureVisible(output);
      expect(output, findsOneWidget);
      expect(find.text('Failed check tool output'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        sdk,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(sdk, '/different-sdk');
      await tester.pumpAndSettle();
      expect(controller.checkOutput, isNull);
      expect(find.text('Failed check tool output'), findsNothing);
      await runChecks(controller);
      await tester.pumpAndSettle();
      final python = find.widgetWithText(TextField, 'Python executable path');
      await tester.scrollUntilVisible(
        python,
        -180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(python, '/different-python');
      await tester.pumpAndSettle();
      expect(controller.checkOutput, isNull);
      await runChecks(controller);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        pick,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(pick);
      await tester.pumpAndSettle();
      expect(controller.checkOutput, isNull);
    },
  );

  testWidgets('candidate approval rechecks the displayed digest', (
    tester,
  ) async {
    final first = 'a' * 64;
    var digest = first;
    var scans = 0;
    final controller = SelfSnapshotController(
      compare:
          ({
            required snapshot,
            required source,
            required commit,
            required python,
            required stop,
            required stopped,
          }) async {
            expect(source, '/source');
            expect(commit, commitId);
            scans++;
            return comparison(digest, commitId);
          },
      fingerprint:
          ({
            required snapshot,
            required python,
            required stop,
            required stopped,
          }) async {
            expect(snapshot, '/destination');
            expect(python, '/python');
            scans++;
            return digest;
          },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SelfSnapshotScreen(
          controller: controller,
          picker: FixturePicker(),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField).at(0), commitId);
    await tester.enterText(find.byType(TextField).at(1), '/python');
    await tester.tap(find.text('Choose trusted checkout'));
    await tester.pumpAndSettle();
    final pick = find.text('Choose prepared snapshot for checks');
    await tester.ensureVisible(pick);
    await tester.tap(pick);
    await tester.pumpAndSettle();
    final review = find.text('Review candidate fingerprint');
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pumpAndSettle();
    expect(find.textContaining('SHA-256: $first'), findsOneWidget);
    expect(
      find.textContaining('Compared with selected repository/commit'),
      findsOneWidget,
    );
    expect(
      find.textContaining('does not verify candidate origin'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(scans, 1);
    await tester.tap(review);
    await tester.pumpAndSettle();
    digest = 'b' * 64;
    await tester.tap(find.text('Approve candidate'));
    await tester.pumpAndSettle();
    expect(controller.status, contains('Candidate changed'));
    await tester.ensureVisible(review);
    await tester.tap(review);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve candidate'));
    await tester.pumpAndSettle();
    expect(
      controller.status,
      'Candidate approved for review only. SHA-256: $digest',
    );
    expect(scans, 5);
  });

  testWidgets(
    'comparison dialog remains usable with truncated paths at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      final controller = SelfSnapshotController(
        compare:
            ({
              required snapshot,
              required source,
              required commit,
              required python,
              required stop,
              required stopped,
            }) async {
              calls++;
              return CandidateComparison.decode(
                jsonEncode({
                  'schemaVersion': 1,
                  'commit': commit,
                  'digest': 'a' * 64,
                  'counts': {
                    'added': 101,
                    'modified': 0,
                    'removed': 0,
                    'executableChanged': 0,
                  },
                  'changes': List.generate(
                    100,
                    (i) => {
                      'path': 'file${i.toString().padLeft(3, '0')}.dart',
                      'kind': 'added',
                      'executableChanged': false,
                    },
                  ),
                  'truncated': true,
                }),
              );
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SelfSnapshotScreen(
            controller: controller,
            picker: FixturePicker(),
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Reviewed commit ID'),
        commitId,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Python executable path'),
        '/python',
      );
      await tester.tap(find.text('Choose trusted checkout'));
      await tester.pumpAndSettle();
      final pick = find.text('Choose prepared snapshot for checks');
      await tester.scrollUntilVisible(
        pick,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(pick);
      await tester.pumpAndSettle();
      final review = find.text('Review candidate fingerprint');
      await tester.scrollUntilVisible(
        review,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.textContaining('101 added'), findsOneWidget);
      expect(find.textContaining('Change list truncated'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('Candidate execution is disabled'),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(controller.status, isNull);
    },
  );

  test('build result requires a confined artifact path on success', () {
    final result = <String, Object>{
      'exitCode': 0,
      'output': '',
      'timedOut': false,
      'outputLimitExceeded': false,
      'cancelled': false,
    };
    GenerationCommandResult decode() => GenerationCommandResult.decode(
      jsonEncode(result),
      expectWebArtifact: true,
    );
    expect(decode, throwsFormatException);
    result['artifactPath'] = 'build/../asg-web-abcdefgh';
    expect(decode, throwsFormatException);
    result['artifactPath'] = 'build/asg-web-abcdefgh';
    expect(decode().artifactPath, 'build/asg-web-abcdefgh');
    result['exitCode'] = 1;
    expect(decode, throwsFormatException);
    result.remove('artifactPath');
    expect(decode().artifactPath, isNull);
  });

  testWidgets(
    'prepared snapshot handoff requires selection and check approval',
    (tester) async {
      const prepared = '/destination/asg-self-candidate-a1b2c3d4/source-new';
      final calls = <SelfSnapshotOperation>[];
      final controller = SelfSnapshotController(
        prepare: ({
          required source,
          required destination,
          required commit,
          required python,
          required stop,
          required stopped,
        }) async => prepared,
        check:
            ({
              required snapshot,
              required sdk,
              required python,
              required operation,
              required stop,
              required stopped,
            }) async {
              expect(snapshot, prepared);
              calls.add(operation);
              return const GenerationCommandResult(exitCode: 0, output: '');
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SelfSnapshotScreen(
            controller: controller,
            picker: FixturePicker(['/source', '/destination', '/older']),
          ),
        ),
      );
      Future<void> tap(String label) async {
        final item = find.text(label);
        await tester.ensureVisible(item);
        await tester.tap(item);
        await tester.pumpAndSettle();
      }

      await tap('Choose trusted checkout');
      await tap('Choose snapshot destination');
      await tester.enterText(find.byType(TextField).at(0), commitId);
      await tester.enterText(find.byType(TextField).at(1), '/python');
      await tap('Choose prepared snapshot for checks');
      final sdk = find.widgetWithText(TextField, 'Flutter SDK folder');
      await tester.scrollUntilVisible(
        sdk,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(sdk, '/sdk');
      await tap('Prepare source snapshot');
      expect(find.text('/older'), findsOneWidget);
      expect(find.text(prepared), findsNothing);
      expect(calls, isEmpty);
      await tap('Use prepared snapshot');
      expect(find.text('/older'), findsNothing);
      expect(find.text(prepared), findsOneWidget);
      expect(find.text('Use prepared snapshot'), findsNothing);
      expect(calls, isEmpty);
      await tap('Review offline checks');
      expect(find.textContaining(prepared), findsAtLeastNWidgets(1));
      expect(calls, isEmpty);
      await tap('Approve and run');
      expect(calls, [
        SelfSnapshotOperation.resolve,
        SelfSnapshotOperation.analyze,
      ]);
    },
  );

  testWidgets('shows the exact retained run after preparation fails', (
    tester,
  ) async {
    const run = '/destination/asg-self-candidate-a1b2c3d4';
    var paths = ['/destination/another-run'];
    final controller = SelfSnapshotController(
      inspect: (_) async =>
          SnapshotRecoveryInventory(paths: paths, additionalCount: 1),
      prepare: ({
        required source,
        required destination,
        required commit,
        required python,
        required stop,
        required stopped,
      }) async => throw const SnapshotPreparationFailure(run),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SelfSnapshotScreen(
          controller: controller,
          picker: FixturePicker(),
        ),
      ),
    );
    await tester.tap(find.text('Choose trusted checkout'));
    await tester.pump();
    await tester.tap(find.text('Choose snapshot destination'));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), commitId);
    await tester.enterText(find.byType(TextField).at(1), '/python');
    await tester.tap(find.text('Prepare source snapshot'));
    await tester.pumpAndSettle();

    final status = tester.widget<SelectableText>(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && (widget.data?.contains(run) ?? false),
      ),
    );
    expect(status.data, startsWith('Preparation failed.'));
    expect(find.textContaining('Snapshot ready'), findsNothing);
    expect(find.text('Use prepared snapshot'), findsNothing);

    await controller.inspect('/destination');
    expect(controller.status, contains(run));
    expect(controller.status, contains('/destination/another-run'));
    paths = [run];
    await controller.inspect('/destination');
    expect(
      controller.status!.split('\n').where((line) => line == run),
      hasLength(1),
    );

    paths = [];
    await controller.inspect('/other');
    expect(controller.status, isNot(contains(run)));
  });

  test('early retry preserves the last confirmed retained run', () async {
    const original = '/destination/asg-self-candidate-a1b2c3d4';
    const replacement = '/destination/asg-self-candidate-d4c3b2a1';
    var attempts = 0;
    final controller = SelfSnapshotController(
      prepare:
          ({
            required source,
            required destination,
            required commit,
            required python,
            required stop,
            required stopped,
          }) async {
            switch (++attempts) {
              case 1:
                throw const SnapshotPreparationFailure(original);
              case 2:
                throw StateError('Preparation failed before allocating a run.');
              default:
                throw const SnapshotPreparationFailure(replacement);
            }
          },
      inspect: (_) async =>
          SnapshotRecoveryInventory(paths: [], additionalCount: 0),
    );
    addTearDown(controller.dispose);

    Future<void> prepare() => controller.prepare(
      source: '/source',
      destination: '/destination',
      commit: commitId,
      python: '/python',
    );

    await prepare();
    await prepare();
    await controller.inspect('/destination');
    expect(controller.status, contains(original));

    await controller.inspect('/different');
    expect(controller.status, isNot(contains(original)));
    await controller.inspect('/destination');
    expect(controller.status, contains(original));

    await prepare();
    await controller.inspect('/destination');
    expect(controller.status, contains(replacement));
    expect(controller.status, isNot(contains(original)));
  });

  test(
    'Stop shows the retained run without reporting a ready snapshot',
    () async {
      final result = Completer<String>();
      final controller = SelfSnapshotController(
        prepare: ({
          required source,
          required destination,
          required commit,
          required python,
          required stop,
          required stopped,
        }) => result.future,
      );
      addTearDown(controller.dispose);
      final preparation = controller.prepare(
        source: '/source',
        destination: '/destination',
        commit: commitId,
        python: '/python',
      );
      controller.stop();
      result.completeError(
        const SnapshotPreparationFailure(
          '/destination/asg-self-candidate-a1b2c3d4',
        ),
      );
      await preparation;
      expect(
        controller.status,
        'Preparation stopped. Inspect the run folder before retrying.\n'
        '/destination/asg-self-candidate-a1b2c3d4',
      );
    },
  );

  test('ignores a recovery receipt received after disposal', () async {
    final result = Completer<String>();
    final controller = SelfSnapshotController(
      prepare: ({
        required source,
        required destination,
        required commit,
        required python,
        required stop,
        required stopped,
      }) => result.future,
    );
    final preparation = controller.prepare(
      source: '/source',
      destination: '/destination',
      commit: commitId,
      python: '/python',
    );
    controller.dispose();
    result.completeError(
      const SnapshotPreparationFailure(
        '/destination/asg-self-candidate-a1b2c3d4',
      ),
    );
    await preparation;
    expect(controller.status, isNull);
  });

  testWidgets(
    'prepares only on explicit action and ignores a late Stop result',
    (tester) async {
      final result = Completer<String>();
      var calls = 0;
      final controller = SelfSnapshotController(
        prepare:
            ({
              required source,
              required destination,
              required commit,
              required python,
              required stop,
              required stopped,
            }) {
              calls++;
              expect(
                (source, destination, commit, python),
                ('/source', '/destination', commitId, '/python'),
              );
              return result.future;
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SelfSnapshotScreen(
            controller: controller,
            picker: FixturePicker(),
          ),
        ),
      );
      await tester.tap(find.text('Choose trusted checkout'));
      await tester.pump();
      await tester.tap(find.text('Choose snapshot destination'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), commitId);
      await tester.enterText(find.byType(TextField).at(1), '/python');
      expect(calls, 0);
      await tester.tap(find.text('Prepare source snapshot'));
      await tester.pump();
      expect(calls, 1);
      await tester.tap(find.text('Stop'));
      await tester.pump();
      result.complete('/ready');
      await tester.pump();
      expect(find.textContaining('Preparation stopped'), findsOneWidget);
      expect(find.textContaining('Snapshot ready'), findsNothing);
      expect(find.text('Use prepared snapshot'), findsNothing);
    },
  );

  test('invalid commit is rejected before starting a process', () async {
    final controller = SelfSnapshotController();
    addTearDown(controller.dispose);
    await controller.prepare(
      source: '/source',
      destination: '/destination',
      commit: 'HEAD',
      python: '/python',
    );
    expect(controller.busy, isFalse);
    expect(controller.status, contains('full commit ID'));
  });
  testWidgets('inspection uses the selected destination without preparation', (
    tester,
  ) async {
    final pending = Completer<SnapshotRecoveryInventory>();
    final picker = FixturePicker()..folders.moveNext();
    final controller = SelfSnapshotController(
      inspect: (destination) {
        expect(destination, '/destination');
        return pending.future;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SelfSnapshotScreen(controller: controller, picker: picker),
      ),
    );
    await tester.tap(find.text('Choose snapshot destination'));
    await tester.pump();
    await tester.ensureVisible(find.text('Find incomplete snapshots'));
    await tester.tap(find.text('Find incomplete snapshots'));
    await tester.pump();
    expect(find.text('Inspecting destination…'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    const shown = '/destination/asg-self-candidate-a1b2c3d4/incomplete';
    pending.complete(
      SnapshotRecoveryInventory(paths: [shown], additionalCount: 1),
    );
    await tester.pump();
    expect(
      find.textContaining('Possible incomplete snapshot folders'),
      findsOneWidget,
    );
    expect(find.textContaining(shown), findsOneWidget);
    expect(
      find.textContaining(
        'Inspect the listed folders before retrying preparation.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('1 additional folder found.'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Choose snapshot destination'),
      -180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose snapshot destination'));
    await tester.pump();
    expect(
      find.textContaining('Possible incomplete snapshot folders'),
      findsOneWidget,
    );
  });
  test('checks require approval and Stop suppresses analysis', () async {
    final result = Completer<GenerationCommandResult>();
    final calls = <bool>[];
    final controller = SelfSnapshotController(
      check:
          ({
            required snapshot,
            required sdk,
            required python,
            required operation,
            required stop,
            required stopped,
          }) {
            expect((snapshot, sdk, python), ('/snapshot', '/sdk', '/python'));
            calls.add(operation == SelfSnapshotOperation.analyze);
            return result.future;
          },
    );
    addTearDown(controller.dispose);
    Future<void> run(bool approved) => controller.check(
      approved: approved,
      snapshot: '/snapshot',
      sdk: '/sdk',
      python: '/python',
    );
    await run(false);
    expect(calls, isEmpty);
    final operation = run(true);
    expect(calls, [false]);
    controller.stop();
    result.complete(const GenerationCommandResult(exitCode: 0, output: ''));
    await operation;
    expect(calls, [false]);
    expect(controller.status, 'Snapshot checks stopped.');
  });

  test(
    'analyze runs only after successful resolve and reports actual exit',
    () async {
      final calls = <bool>[];
      final controller = SelfSnapshotController(
        check:
            ({
              required snapshot,
              required sdk,
              required python,
              required operation,
              required stop,
              required stopped,
            }) async {
              calls.add(operation == SelfSnapshotOperation.analyze);
              return GenerationCommandResult(
                exitCode: operation == SelfSnapshotOperation.analyze ? 1 : 0,
                output: '',
              );
            },
      );
      addTearDown(controller.dispose);
      await controller.check(
        approved: true,
        snapshot: '/snapshot',
        sdk: '/sdk',
        python: '/python',
      );
      expect(calls, [false, true]);
      expect(
        controller.status,
        'Offline dependency resolution passed.\nAnalysis failed (exit 1).',
      );
    },
  );
  testWidgets(
    'review names the selected snapshot and Cancel starts no checks',
    (tester) async {
      final calls = <SelfSnapshotOperation>[];
      final controller = SelfSnapshotController(
        check:
            ({
              required snapshot,
              required sdk,
              required python,
              required operation,
              required stop,
              required stopped,
            }) async {
              expect((snapshot, sdk, python), ('/source', '/sdk', '/python'));
              calls.add(operation);
              return GenerationCommandResult(
                exitCode: 0,
                output: '',
                artifactPath: operation == SelfSnapshotOperation.build
                    ? 'build/asg-web-fixture0'
                    : null,
              );
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SelfSnapshotScreen(
            controller: controller,
            picker: FixturePicker(),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).at(1), '/python');
      final pick = find.text('Choose prepared snapshot for checks');
      await tester.ensureVisible(pick);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, 'Flutter SDK folder');
      await tester.scrollUntilVisible(
        field,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(field, '/sdk');
      final review = find.text('Review offline checks');
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(find.textContaining('Flutter SDK: /sdk'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve and run'));
      await tester.pumpAndSettle();
      expect(calls, [
        SelfSnapshotOperation.resolve,
        SelfSnapshotOperation.analyze,
      ]);
      expect(controller.status, contains('Analysis passed'));
      calls.clear();
      final build = find.widgetWithText(
        OutlinedButton,
        'Review offline web build',
      );
      await tester.scrollUntilVisible(
        build,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(build);
      await tester.pumpAndSettle();
      expect(find.text('Approve offline web build?'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('Approve and run'));
      await tester.pumpAndSettle();
      expect(calls, [
        SelfSnapshotOperation.resolve,
        SelfSnapshotOperation.build,
      ]);
      expect(
        controller.status,
        contains('Web artifacts at /source/asg/build/asg-web-fixture0'),
      );
    },
  );
}
